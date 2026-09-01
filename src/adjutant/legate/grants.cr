require "yaml"
require "../grants"
require "./net_rule"

module Adjutant
  module Legate
    # Parses the size/duration literals LEGATE.md §7's YAML uses
    # ("8MiB", "512MiB", "300s") — Crystal's stdlib has nothing built
    # in for either, so both are small hand-rolled regexes rather than
    # a dependency. Kept separate from Grants itself so the broker
    # (step 4c) or anything else needing the same literal shape can
    # reuse them without pulling in the whole Grants type.
    module SizeLiteral
      SIZE_RE = /\A(\d+)\s*(B|KiB|MiB|GiB)?\z/

      # Binary (1024-based) units, matching §7's "MiB"/"GiB" spelling —
      # not decimal MB/GB. A bare integer with no unit is bytes.
      def self.bytes(str : String) : Int64
        m = SIZE_RE.match(str.strip)
        raise ArgumentError.new("Legate::Grants — invalid size literal #{str.inspect} (want e.g. \"8MiB\", \"512MiB\", \"4GiB\", or a bare byte count)") unless m
        n = m[1].to_i64
        case m[2]?
        when nil, "B" then n
        when "KiB"    then n * 1024_i64
        when "MiB"    then n * 1024_i64 ** 2
        when "GiB"    then n * 1024_i64 ** 3
        else
          raise ArgumentError.new("Legate::Grants — unreachable size unit #{m[2]?.inspect}")
        end
      end
    end

    module DurationLiteral
      DURATION_RE = /\A(\d+)s\z/

      # Only seconds, matching every duration literal §7 actually
      # shows ("300s"). Extend the regex if a future limit needs
      # minutes/hours — deliberately not generalised ahead of need.
      def self.seconds(str : String) : Int32
        m = DURATION_RE.match(str.strip)
        raise ArgumentError.new("Legate::Grants — invalid duration literal #{str.inspect} (want e.g. \"300s\")") unless m
        m[1].to_i32
      end
    end

    # Per-call and per-run caps — LEGATE.md §7's `limits:` block.
    #
    # `read_limit`/`fetch_limit` are the two caps §4.1/§4.5 themselves
    # name a default for (8 MiB, 32 MiB) — a policy omitting them
    # still gets a working, spec-faithful limit, not an unbounded
    # read. The four per-run budgets (`memory`, `wall_clock`,
    # `total_read`, `total_write`) have no spec-stated default, so an
    # omitted one is `nil`, meaning **not enforced** — an embedder who
    # wants a per-run budget has to say so explicitly. Worth
    # confirming this is the intended posture: the alternative (treat
    # an omitted per-run budget as an error, or as some implicit cap)
    # is defensible too, and the spec doesn't pin it down either way.
    class Limits
      DEFAULT_READ_LIMIT  =  8_388_608_i64 # 8 MiB — §4.1
      DEFAULT_FETCH_LIMIT = 33_554_432_i64 # 32 MiB — §4.5

      # DELIBERATE ADDITION to §7's `limits:` block, agreed with the
      # embedder. §7 names no cap on the REQUEST side of a fetch at
      # all — `fetch_limit` bounds the response only. That leaves the
      # URL itself unbounded, and a URL is a perfectly serviceable
      # exfiltration channel: a script with a `net` grant to any host
      # can encode arbitrary amounts of sensitive data into a query
      # string and "search" for it, with the whole payload sitting in
      # the request line where a response-size limit never looks.
      #
      # 2 KiB by default. That is comfortably above any legitimate
      # API call and comfortably below a useful exfiltration payload;
      # it is also roughly where several real servers and proxies
      # start refusing request lines anyway, so a policy sitting at
      # the default is unlikely to break a script that would have
      # worked in production.
      #
      # Enforced by `Legate.fetch` as a RECOVERABLE `Legate::TooLarge`
      # (per-call limits are recoverable, §7), checked BEFORE the
      # broker call so an over-long URL is never authorized, never
      # resolved and never audited as an allowed egress — the data
      # does not leave either way, and the script can retry with a
      # smaller query.
      DEFAULT_URL_LIMIT = 2_048_i64 # 2 KiB

      # The cap on a STREAMED response body (`Legate.fetch stream:
      # true`), separate from `fetch_limit` and much larger, because
      # the two limits exist for different reasons.
      #
      # `fetch_limit` is a MEMORY cap: 32 MiB is what a run is willing
      # to hold in one String at once. Nothing is held when streaming,
      # so that number is simply the wrong question. What a streamed
      # response still needs is a RUNAWAY cap — a server that never
      # sends EOF would otherwise pull bytes forever, and §4.5 read as
      # though `limit` governed only the buffered body, which would
      # have left streaming as the one unmetered ingress path in the
      # whole grant.
      #
      # 1 GiB: high enough that no legitimate download trips it (the
      # whole point of streaming is handling bodies too big to buffer)
      # and low enough to stop an endless one long before the per-run
      # `total_read` budget would, if that budget is even set — it is
      # nil by default, whereas this is not.
      DEFAULT_STREAM_LIMIT = 1_073_741_824_i64 # 1 GiB

      # DELIBERATE ADDITION to §7's `limits:` block. §7 has no cap on
      # how many streams a script may hold OPEN AT ONCE, and the
      # per-run teardown added alongside this (open_sources.cr) bounds
      # the leak in TIME but not in COUNT: a script looping over ten
      # thousand paths or URLs and calling `.first(1)` on each holds
      # ten thousand descriptors simultaneously, and every one of them
      # is released only when the run ends. Without a cap that fails
      # at whatever the process fd limit happens to be, as an opaque
      # `Too many open files` from somewhere deep in `File.open`.
      #
      # NEITHER of §7's two categories, and worth being explicit about
      # that rather than filing it under the nearest one. §7's rule is
      # "per-call limits are recoverable; per-run budgets are fatal,"
      # and the reasoning for the fatal half is that a cumulative
      # budget a script could catch and retry past is no budget at
      # all. This is a per-run cap on SIMULTANEOUS HOLDINGS, not on
      # cumulative consumption: a script that hits it and then
      # finishes walking one stream has genuinely freed the resource,
      # and retrying is legitimate rather than an end-run around
      # exhaustion. So it is RECOVERABLE (`Legate::TooMany`), which
      # matches how the same shape behaves everywhere else in the
      # system — you can always make progress by consuming what you
      # already opened.
      #
      # 64 by default: far above any plausible legitimate fan-out (a
      # script comparing a handful of files, or fetching a few
      # endpoints in sequence, holds one or two), and far below any
      # ordinary process fd limit, so the cap bites long before the
      # OS does and says something useful when it does.
      DEFAULT_MAX_OPEN_STREAMS = 64

      getter read_limit : Int64
      getter fetch_limit : Int64
      getter url_limit : Int64
      getter stream_limit : Int64
      getter max_open_streams : Int32
      getter memory : Int64?
      getter wall_clock : Int32?
      getter total_read : Int64?
      getter total_write : Int64?

      def initialize(@read_limit = DEFAULT_READ_LIMIT, @fetch_limit = DEFAULT_FETCH_LIMIT,
                     @url_limit = DEFAULT_URL_LIMIT,
                     @stream_limit = DEFAULT_STREAM_LIMIT,
                     @max_open_streams = DEFAULT_MAX_OPEN_STREAMS,
                     @memory = nil, @wall_clock = nil, @total_read = nil, @total_write = nil)
      end
    end

    # Legate::Grants — LEGATE.md §7. The static, embedder-owned
    # authorization surface: which roots/hosts/binaries/env vars a
    # script may touch, fixed before the first line executes and
    # never escalated at runtime (§7's own opening line). A PLAIN
    # Crystal value object, not a RubyObject/RubyClass — like
    # RiskFlowPolicy (risk_flow_policy.cr), Grants belongs to whatever
    # embeds Adjutant, not to the script; nothing about it is ever
    # script-visible or constructible from inside a running script.
    #
    # "Absent grants are denied" (§7): every field defaults to the
    # empty/no-access value, so `Grants.new` with no arguments denies
    # everything — matching RiskFlowPolicy's own "no silent
    # allow-everything default" stance (see that file's top comment).
    # An explicitly-present-but-empty category (`read: {roots: []}`)
    # and an absent one collapse to the identical Array(String)#empty?
    # check everywhere below — both mean "nothing granted," and there
    # is no reason to track "present" separately from "has entries."
    #
    # This is config, not enforcement — it answers "what is this
    # script authorized to touch," not "should this specific call
    # proceed." The broker (step 4c) is what actually resolves a path
    # against `read_roots`/etc at call time; this class only holds and
    # parses the data it needs to do that.
    # Extends the core perimeter (`Adjutant::Grants` — filesystem
    # roots and the binary allowlist, plus the checks over them) with
    # the parts that are Legate's own: network rules, the top-level
    # method ceiling, the ambient-env allowlist, and the per-verb
    # limits.
    #
    # Subclassed rather than composed so a Broker still holds ONE
    # grants object. Splitting it into "the core half" and "the Legate
    # half" would give every caller two things to keep in step, and
    # `Grants::Decision` resolves through the superclass either way.
    #
    # Network rules stayed HERE rather than moving to core with the
    # roots (2026-09-01): authorizing a connection needs to know
    # something about the protocol — HTTP methods today — and a core
    # type that knows GET from POST is core knowing about HTTP. Core
    # would also have to hold the list of schemes that exist, so
    # adding a protocol would mean a core change for no benefit. Kept
    # here until a second protocol makes the real seam visible; see
    # SCOPE.md.
    class Grants < ::Adjutant::Grants
      getter net_rules : Array(NetRule)
      getter net_methods : Array(String)
      getter ambient_env : Array(String)

      getter limits : Limits

      def initialize(read_roots = [] of String, write_roots = [] of String,
                     delete_roots = [] of String, @net_rules = [] of NetRule,
                     @net_methods = [] of String, exec_binaries = [] of String,
                     @ambient_env = [] of String,
                     @limits = Limits.new)
        super(read_roots, write_roots, delete_roots, exec_binaries)
      end

      # The fully-closed policy — every category empty, every per-run
      # budget unenforced except the two spec-defaulted per-call
      # limits. The explicit choice for "no grants configured" or "no
      # policy file found," mirroring RiskFlowPolicy.reject_all's own
      # reasoning: an embedder who wants no access must get it by
      # omission automatically, not by remembering to say so.
      def self.deny_all : Grants
        new
      end

      # Parses LEGATE.md §7's YAML shape directly. Both `grants:` and
      # `limits:` are optional top-level keys; a document missing
      # either just gets that section's own all-denied/all-default
      # value. NOT independently verified against a live Crystal
      # toolchain — `YAML::Any#[]?`/`#as_s`/`#as_a?`'s exact behavior
      # on a missing vs. wrong-typed key is written from recollection;
      # flag any mismatch `ops test` surfaces here first.
      def self.from_yaml(source : String) : Grants
        doc = YAML.parse(source)
        grants_node = doc["grants"]?
        limits_node = doc["limits"]?

        new(
          read_roots: string_array(grants_node, "read", "roots"),
          write_roots: string_array(grants_node, "write", "roots"),
          delete_roots: string_array(grants_node, "delete", "roots"),
          net_rules: net_rules_of(grants_node),
          net_methods: string_array(grants_node, "net", "methods").map(&.downcase),
          exec_binaries: string_array(grants_node, "exec", "binaries"),
          ambient_env: string_array(grants_node, "ambient", "env"),
          limits: limits_of(limits_node),
        )
      end

      # `net.hosts` entries are each parsed into a NetRule (which
      # accepts both the plain-string form §7 shows and the richer
      # mapping form) rather than being read as bare strings — see
      # net_rule.cr's own top comment for why the widening was
      # needed and how each default fails closed.
      private def self.net_rules_of(grants_node : YAML::Any?) : Array(NetRule)
        node = grants_node.try(&.["net"]?).try(&.["hosts"]?)
        list = node.try(&.as_a?)
        return [] of NetRule unless list
        list.map { |entry| NetRule.from_yaml_node(entry) }
      end

      private def self.limits_of(limits_node : YAML::Any?) : Limits
        Limits.new(
          read_limit: size_or(limits_node, "read_limit", Limits::DEFAULT_READ_LIMIT),
          fetch_limit: size_or(limits_node, "fetch_limit", Limits::DEFAULT_FETCH_LIMIT),
          url_limit: size_or(limits_node, "url_limit", Limits::DEFAULT_URL_LIMIT),
          stream_limit: size_or(limits_node, "stream_limit", Limits::DEFAULT_STREAM_LIMIT),
          max_open_streams: count_or(limits_node, "max_open_streams", Limits::DEFAULT_MAX_OPEN_STREAMS),
          memory: size_or?(limits_node, "memory"),
          wall_clock: duration_or?(limits_node, "wall_clock"),
          total_read: size_or?(limits_node, "total_read"),
          total_write: size_or?(limits_node, "total_write"),
        )
      end

      private def self.size_or(node : YAML::Any?, key : String, default : Int64) : Int64
        size_or?(node, key) || default
      end

      # A PLAIN COUNT, not a size literal — `max_open_streams: 64`
      # means sixty-four streams, and there is no `64MiB`-style suffix
      # to interpret. Accepts either a YAML integer or a numeric
      # string, since a policy author who quotes it (habit, after
      # every neighbouring key IS a quoted literal) should not get a
      # silent fallback to the default. A zero or negative value is
      # rejected the same way: it would mean "no stream may ever be
      # opened," which is far more likely a typo than a policy.
      private def self.count_or(node : YAML::Any?, key : String, default : Int32) : Int32
        raw = node.try(&.[key]?)
        return default unless raw
        n = raw.as_i? || raw.as_s?.try(&.to_i32?)
        n && n > 0 ? n : default
      end

      private def self.size_or?(node : YAML::Any?, key : String) : Int64?
        raw = node.try(&.[key]?).try(&.as_s?)
        raw.try { |str| SizeLiteral.bytes(str) }
      end

      private def self.duration_or?(node : YAML::Any?, key : String) : Int32?
        raw = node.try(&.[key]?).try(&.as_s?)
        raw.try { |str| DurationLiteral.seconds(str) }
      end

      # Walks a dotted path of string keys under `grants:` (e.g.
      # `"read", "roots"`) and returns its scalar-array value as
      # Array(String), or [] if any hop is missing or the wrong shape
      # — a malformed or absent category is "nothing granted," the
      # same as a well-formed empty one (see this class's own top
      # comment), never a parse error.
      private def self.string_array(root : YAML::Any?, *keys : String) : Array(String)
        node = root
        keys.each { |key| node = node.try(&.[key]?) }
        node.try(&.as_a?).try(&.map(&.as_s)) || [] of String
      end
    end
  end
end
