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

    # Strict reads from a parsed YAML policy, for `Grants.from_yaml`
    # and `NetRule.from_yaml_node`. Each raises ArgumentError naming
    # the offending path. A key that is absent, or present with no
    # value (`limits:` alone), reads as not given.
    module YamlPolicy
      alias Mapping = Hash(YAML::Any, YAML::Any)

      # `node` as a mapping whose keys are all in `allowed`.
      def self.mapping(node : YAML::Any, path : String, allowed : Enumerable(String)) : Mapping
        hash = node.as_h?
        raise invalid(path, "must be a mapping, got #{describe(node)}") unless hash
        hash.each_key do |key|
          name = key.as_s?
          unless name && allowed.includes?(name)
            raise invalid(path, "has an unknown key #{key.raw.inspect}; expected one of #{allowed.join(", ")}")
          end
        end
        hash
      end

      # The value under `key`, or nil if not given.
      def self.value(parent : Mapping?, key : String) : YAML::Any?
        node = parent.try(&.[YAML::Any.new(key)]?)
        node unless node.nil? || node.raw.nil?
      end

      # The mapping under `key`, checked against `allowed`, or nil if
      # not given.
      def self.section(parent : Mapping?, key : String, path : String, allowed : Enumerable(String)) : Mapping?
        node = value(parent, key)
        mapping(node, path, allowed) if node
      end

      # The list under `key`, or empty if not given.
      def self.list(parent : Mapping?, key : String, path : String) : Array(YAML::Any)
        node = value(parent, key)
        return [] of YAML::Any unless node
        node.as_a? || raise invalid(path, "must be a list, got #{describe(node)}")
      end

      # The list of strings under `key`, or empty if not given.
      def self.strings(parent : Mapping?, key : String, path : String) : Array(String)
        list(parent, key, path).map do |entry|
          entry.as_s? || raise invalid(path, "must list strings, got #{describe(entry)}")
        end
      end

      # A positive byte count, as a YAML integer or a size literal
      # ("8MiB", "1048576"), or nil if not given.
      def self.size(parent : Mapping?, key : String) : Int64?
        node = value(parent, key)
        return unless node
        bytes = node.as_i64? || node.as_s?.try { |str| SizeLiteral.bytes(str) }
        raise invalid("limits.#{key}", "must be a size such as 8MiB or a byte count, got #{describe(node)}") unless bytes
        raise invalid("limits.#{key}", "must be positive, got #{bytes}") unless bytes > 0
        bytes
      end

      # A positive number of seconds, as a YAML integer or a duration
      # literal ("300s"), or nil if not given.
      def self.seconds(parent : Mapping?, key : String) : Int32?
        node = value(parent, key)
        return unless node
        n = node.as_i64? || node.as_s?.try { |str| DurationLiteral.seconds(str).to_i64 }
        raise invalid("limits.#{key}", "must be a duration such as 300s, got #{describe(node)}") unless n
        in_int32_range!("limits.#{key}", n)
      end

      # A positive count, as a YAML integer, or nil if not given.
      def self.count(parent : Mapping?, key : String) : Int32?
        node = value(parent, key)
        return unless node
        n = node.as_i64?
        raise invalid("limits.#{key}", "must be a whole number, got #{describe(node)}") unless n
        in_int32_range!("limits.#{key}", n)
      end

      # A boolean, or `default` if not given.
      def self.bool(parent : Mapping?, key : String, path : String, default : Bool) : Bool
        node = value(parent, key)
        return default unless node
        flag = node.as_bool?
        raise invalid(path, "must be true or false, got #{describe(node)}") if flag.nil?
        flag
      end

      # A string, or nil if not given.
      def self.string(parent : Mapping?, key : String, path : String) : String?
        node = value(parent, key)
        return unless node
        node.as_s? || raise invalid(path, "must be a string, got #{describe(node)}")
      end

      private def self.in_int32_range!(path : String, n : Int64) : Int32
        raise invalid(path, "must be positive, got #{n}") unless n > 0
        raise invalid(path, "is too large: #{n}") if n > Int32::MAX
        n.to_i32
      end

      def self.invalid(path : String, problem : String) : ArgumentError
        ArgumentError.new("Legate::Grants — #{path} #{problem}")
      end

      # The node as the author wrote it, for messages.
      private def self.describe(node : YAML::Any) : String
        case raw = node.raw
        when Hash  then "a mapping"
        when Array then "a list"
        else            raw.inspect
        end
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
      # recoverable `Legate::TooLargeError`.
      DEFAULT_URL_LIMIT = 2_048_i64 # 2 KiB

      # The cap on a streamed response body. `fetch_limit` caps what is
      # held in memory, which streaming doesn't do; this stops a server
      # that never sends EOF. Set by default, unlike `total_read`.
      DEFAULT_STREAM_LIMIT = 1_073_741_824_i64 # 1 GiB

      # How many streams may be open at once, an addition to §7.
      # `OpenSources` closes leftovers when the run ends, which bounds a
      # leak in time but not in count. Recoverable
      # (`Legate::TooManyError`), unlike a per-run budget: it caps what
      # is held, not what is consumed, and closing a stream frees it.

      getter read_limit : Int64
      getter fetch_limit : Int64
      getter url_limit : Int64
      getter stream_limit : Int64

      def initialize(@read_limit = DEFAULT_READ_LIMIT, @fetch_limit = DEFAULT_FETCH_LIMIT,
                     @url_limit = DEFAULT_URL_LIMIT,
                     @stream_limit = DEFAULT_STREAM_LIMIT,
                     max_open_streams = DEFAULT_MAX_OPEN_STREAMS,
                     memory : Int64? = DEFAULT_MEMORY, wall_clock : Int32? = DEFAULT_WALL_CLOCK,
                     total_read : Int64? = DEFAULT_TOTAL_READ, total_write : Int64? = DEFAULT_TOTAL_WRITE)
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
      # Request headers a script's call may carry past a redirect to
      # another origin, lowercase, in addition to
      # `Verbs::Fetch::REDIRECT_HEADERS` (LEGATE.md §8.2).
      getter net_redirect_headers : Array(String)
      getter ambient_env : Array(String)

      getter limits : Limits

      def initialize(read_roots = [] of String, write_roots = [] of String,
                     delete_roots = [] of String, @net_rules = [] of NetRule,
                     @net_methods = [] of String,
                     @ambient_env = [] of String,
                     @limits = Limits.new,
                     net_redirect_headers = [] of String)
        super(read_roots, write_roots, delete_roots)
        @net_redirect_headers = net_redirect_headers.map(&.downcase)
      end

      # Grants nothing, with default limits: the choice for no policy
      # at all.
      def self.deny_all : Grants
        new
      end

      # Parses §7's YAML strictly. `grants:` and `limits:` are both
      # optional, and a missing or empty section is all-denied or
      # all-default, as is an empty document. Anything present must be
      # well-formed: an unknown key, a value of the wrong type or an
      # out-of-range number raises ArgumentError naming where, so a
      # mistake reaches the policy's author when it is loaded rather
      # than silently granting more, or enforcing less, than written.
      def self.from_yaml(source : String) : Grants
        doc = YAML.parse(source)
        return deny_all if doc.raw.nil?

        top = YamlPolicy.mapping(doc, "the document", TOP_KEYS)
        grants_node = YamlPolicy.section(top, "grants", "grants", GRANTS_KEYS)
        limits_node = YamlPolicy.section(top, "limits", "limits", LIMITS_KEYS)
        net = YamlPolicy.section(grants_node, "net", "grants.net", NET_KEYS)

        new(
          read_roots: roots_of(grants_node, "read"),
          write_roots: roots_of(grants_node, "write"),
          delete_roots: roots_of(grants_node, "delete"),
          net_rules: net_rules_of(net),
          net_methods: YamlPolicy.strings(net, "methods", "grants.net.methods").map(&.downcase),
          net_redirect_headers: YamlPolicy.strings(net, "redirect_headers", "grants.net.redirect_headers"),
          ambient_env: YamlPolicy.strings(
            YamlPolicy.section(grants_node, "ambient", "grants.ambient", AMBIENT_KEYS), "env", "grants.ambient.env"),
          limits: limits_of(limits_node),
        )
      end

      TOP_KEYS     = {"grants", "limits"}
      GRANTS_KEYS  = {"read", "write", "delete", "net", "ambient"}
      ROOTS_KEYS   = {"roots"}
      NET_KEYS     = {"methods", "redirect_headers", "hosts"}
      AMBIENT_KEYS = {"env"}
      LIMITS_KEYS  = {"read_limit", "fetch_limit", "url_limit", "stream_limit", "max_open_streams",
                      "memory", "wall_clock", "total_read", "total_write"}

      private def self.roots_of(grants_node : YamlPolicy::Mapping?, category : String) : Array(String)
        section = YamlPolicy.section(grants_node, category, "grants.#{category}", ROOTS_KEYS)
        YamlPolicy.strings(section, "roots", "grants.#{category}.roots")
      end

      # Each `net.hosts` entry, as a string or a mapping; see
      # net_rule.cr.
      private def self.net_rules_of(net : YamlPolicy::Mapping?) : Array(NetRule)
        list = YamlPolicy.list(net, "hosts", "grants.net.hosts")
        list.map { |entry| NetRule.from_yaml_node(entry) }
      end

      private def self.limits_of(node : YamlPolicy::Mapping?) : Limits
        Limits.new(
          read_limit: YamlPolicy.size(node, "read_limit") || Limits::DEFAULT_READ_LIMIT,
          fetch_limit: YamlPolicy.size(node, "fetch_limit") || Limits::DEFAULT_FETCH_LIMIT,
          url_limit: YamlPolicy.size(node, "url_limit") || Limits::DEFAULT_URL_LIMIT,
          stream_limit: YamlPolicy.size(node, "stream_limit") || Limits::DEFAULT_STREAM_LIMIT,
          max_open_streams: YamlPolicy.count(node, "max_open_streams") || Limits::DEFAULT_MAX_OPEN_STREAMS,
          memory: YamlPolicy.size(node, "memory") || Limits::DEFAULT_MEMORY,
          wall_clock: YamlPolicy.seconds(node, "wall_clock") || Limits::DEFAULT_WALL_CLOCK,
          total_read: YamlPolicy.size(node, "total_read") || Limits::DEFAULT_TOTAL_READ,
          total_write: YamlPolicy.size(node, "total_write") || Limits::DEFAULT_TOTAL_WRITE,
        )
      end
    end
  end
end
