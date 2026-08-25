require "yaml"

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

      getter read_limit : Int64
      getter fetch_limit : Int64
      getter memory : Int64?
      getter wall_clock : Int32?
      getter total_read : Int64?
      getter total_write : Int64?

      def initialize(@read_limit = DEFAULT_READ_LIMIT, @fetch_limit = DEFAULT_FETCH_LIMIT,
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
    class Grants
      getter read_roots : Array(String)
      getter write_roots : Array(String)
      getter delete_roots : Array(String)
      getter net_hosts : Array(String)
      getter net_methods : Array(String)
      getter exec_binaries : Array(String)
      getter ambient_env : Array(String)

      # `:pinned` or `:live` — §7's `ambient.now`. A mode, not a
      # yes/no grant, so it doesn't fit the Array(String)-empty-means-
      # denied shape the other seven fields share. Defaults to `:live`
      # (real wall-clock time) rather than `:pinned`, since pinning is
      # the deliberate opt-in for determinism (§2.8), not the safe
      # default — unlike every other field here, "absent" for `now`
      # isn't "denied," it's "ordinary behavior."
      getter ambient_now : Symbol

      getter limits : Limits

      def initialize(@read_roots = [] of String, @write_roots = [] of String,
                     @delete_roots = [] of String, @net_hosts = [] of String,
                     @net_methods = [] of String, @exec_binaries = [] of String,
                     @ambient_env = [] of String, @ambient_now = :live,
                     @limits = Limits.new)
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
          net_hosts: string_array(grants_node, "net", "hosts"),
          net_methods: string_array(grants_node, "net", "methods").map(&.downcase),
          exec_binaries: string_array(grants_node, "exec", "binaries"),
          ambient_env: string_array(grants_node, "ambient", "env"),
          ambient_now: ambient_now_of(grants_node),
          limits: limits_of(limits_node),
        )
      end

      # Convenience over `from_yaml` for the common case of a policy
      # file on disk — separated purely so specs (and callers with an
      # in-memory YAML string, e.g. a test fixture or an embedded
      # default) can call `from_yaml` directly without a real file.
      def self.from_file(path : String) : Grants
        from_yaml(File.read(path))
      end

      private def self.ambient_now_of(grants_node : YAML::Any?) : Symbol
        raw = grants_node.try(&.["ambient"]?).try(&.["now"]?).try(&.as_s?)
        raw == "pinned" ? :pinned : :live
      end

      private def self.limits_of(limits_node : YAML::Any?) : Limits
        Limits.new(
          read_limit: size_or(limits_node, "read_limit", Limits::DEFAULT_READ_LIMIT),
          fetch_limit: size_or(limits_node, "fetch_limit", Limits::DEFAULT_FETCH_LIMIT),
          memory: size_or?(limits_node, "memory"),
          wall_clock: duration_or?(limits_node, "wall_clock"),
          total_read: size_or?(limits_node, "total_read"),
          total_write: size_or?(limits_node, "total_write"),
        )
      end

      private def self.size_or(node : YAML::Any?, key : String, default : Int64) : Int64
        size_or?(node, key) || default
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
