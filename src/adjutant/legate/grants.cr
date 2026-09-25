require "yaml"
require "../grants"
require "../resource_limits"
require "./net_rule"

module Adjutant
  module Legate
    # Parses the size literals LEGATE.md §7's YAML uses ("8MiB",
    # "512MiB").
    module SizeLiteral
      SIZE_RE = /\A(\d+)\s*(B|KiB|MiB|GiB)?\z/

      # Binary units (KiB, MiB, GiB); a bare integer is bytes. Raises
      # ArgumentError for anything else.
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

      # Seconds only ("300s"). Raises ArgumentError for anything else.
      def self.seconds(str : String) : Int32
        m = DURATION_RE.match(str.strip)
        raise ArgumentError.new("Legate::Grants — invalid duration literal #{str.inspect} (want e.g. \"300s\")") unless m
        m[1].to_i32
      end
    end

    # The per-call caps of LEGATE.md §7's `limits:` block, added to
    # core's per-run budgets (`ResourceLimits`). Every per-call cap
    # has a default; an omitted per-run budget is nil, which means not
    # enforced.
    class Limits < ::Adjutant::ResourceLimits
      DEFAULT_READ_LIMIT  =  8_388_608_i64 # 8 MiB — §4.1
      DEFAULT_FETCH_LIMIT = 33_554_432_i64 # 32 MiB — §4.5

      # The longest URL `Legate.fetch` accepts, an addition to §7: a
      # response limit never sees the request, and a query string is
      # an exfiltration channel. Checked before the broker call, so
      # an over-long URL is never authorized or audited; raises the
      # recoverable `Legate::TooLarge`.
      DEFAULT_URL_LIMIT = 2_048_i64 # 2 KiB

      # The cap on a streamed response body. `fetch_limit` caps what is
      # held in memory, which streaming doesn't do; this stops a server
      # that never sends EOF. Set by default, unlike `total_read`.
      DEFAULT_STREAM_LIMIT = 1_073_741_824_i64 # 1 GiB

      # How many streams may be open at once, an addition to §7.
      # `OpenSources` closes leftovers when the run ends, which bounds
      # a leak in time but not in count. Recoverable
      # (`Legate::TooMany`), unlike a per-run budget: it caps what is
      # held, not what is consumed, and closing a stream frees it.

      getter read_limit : Int64
      getter fetch_limit : Int64
      getter url_limit : Int64
      getter stream_limit : Int64

      def initialize(@read_limit = DEFAULT_READ_LIMIT, @fetch_limit = DEFAULT_FETCH_LIMIT,
                     @url_limit = DEFAULT_URL_LIMIT,
                     @stream_limit = DEFAULT_STREAM_LIMIT,
                     max_open_streams = DEFAULT_MAX_OPEN_STREAMS,
                     memory = nil, wall_clock = nil, total_read = nil, total_write = nil)
        super(max_open_streams, memory, wall_clock, total_read, total_write)
      end
    end

    # LEGATE.md §7's grants: which roots, hosts, methods and
    # environment variables a script may touch, fixed before it runs.
    # Host configuration, never visible to a script. Adds network
    # rules, the method ceiling, the environment allowlist and the
    # per-call limits to core's filesystem roots, in one object a
    # Broker holds. Network rules are here, not in core, because
    # authorizing a connection needs HTTP knowledge.
    #
    # Absent grants are denied: `Grants.new` with no arguments denies
    # everything.
    class Grants < ::Adjutant::Grants
      getter net_rules : Array(NetRule)
      getter net_methods : Array(String)
      getter ambient_env : Array(String)

      getter limits : Limits

      def initialize(read_roots = [] of String, write_roots = [] of String,
                     delete_roots = [] of String, @net_rules = [] of NetRule,
                     @net_methods = [] of String,
                     @ambient_env = [] of String,
                     @limits = Limits.new)
        super(read_roots, write_roots, delete_roots)
      end

      # Grants nothing, with default limits: the choice for no policy
      # at all.
      def self.deny_all : Grants
        new
      end

      # Parses §7's YAML. `grants:` and `limits:` are both optional;
      # a missing section is all-denied or all-default.
      def self.from_yaml(source : String) : Grants
        doc = YAML.parse(source)
        # An empty or scalar document grants nothing, as a missing
        # file does.
        return deny_all unless doc.as_h?
        grants_node = doc["grants"]?
        limits_node = doc["limits"]?

        new(
          read_roots: string_array(grants_node, "read", "roots"),
          write_roots: string_array(grants_node, "write", "roots"),
          delete_roots: string_array(grants_node, "delete", "roots"),
          net_rules: net_rules_of(grants_node),
          net_methods: string_array(grants_node, "net", "methods").map(&.downcase),
          ambient_env: string_array(grants_node, "ambient", "env"),
          limits: limits_of(limits_node),
        )
      end

      # Each `net.hosts` entry, as a string or a mapping; see
      # net_rule.cr.
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

      # A positive count, as a YAML integer or a numeric string. A
      # missing, non-numeric, zero or negative value gives the
      # default.
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

      # The string array at `keys` under `grants:`, or [] if any key is
      # missing or the wrong shape.
      private def self.string_array(root : YAML::Any?, *keys : String) : Array(String)
        node = root
        keys.each { |key| node = node.try(&.[key]?) }
        node.try(&.as_a?).try(&.map(&.as_s)) || [] of String
      end
    end
  end
end
