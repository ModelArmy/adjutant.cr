require "../grants"
require "../resource_limits"
require "./net_rule"

module Adjutant
  module Legate
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
    end
  end
end
