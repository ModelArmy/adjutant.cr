require "../policy_section"
require "./grants"

module Adjutant
  module Legate
    # Legate's share of a policy: network rules, the environment
    # allowlist and the per-call limits.
    class PolicyShare < ::Adjutant::PolicyShare
      getter net_rules : Array(NetRule)
      getter net_methods : Array(String)
      getter net_redirect_headers : Array(String)
      getter ambient_env : Array(String)
      getter read_limit : Int64
      getter fetch_limit : Int64
      getter url_limit : Int64
      getter stream_limit : Int64

      def initialize(@net_rules, @net_methods, @net_redirect_headers, @ambient_env,
                     @read_limit, @fetch_limit, @url_limit, @stream_limit)
      end

      # The Grants a Legate broker holds: this share with core's roots
      # and budgets.
      def grants(core : CorePolicyShare) : Grants
        budgets = core.limits
        Grants.new(
          read_roots: core.read_roots,
          write_roots: core.write_roots,
          delete_roots: core.delete_roots,
          net_rules: net_rules,
          net_methods: net_methods,
          net_redirect_headers: net_redirect_headers,
          ambient_env: ambient_env,
          limits: Limits.new(
            read_limit: read_limit, fetch_limit: fetch_limit,
            url_limit: url_limit, stream_limit: stream_limit,
            max_open_streams: budgets.max_open_streams, memory: budgets.memory,
            wall_clock: budgets.wall_clock, total_read: budgets.total_read,
            total_write: budgets.total_write, max_asks: budgets.max_asks,
          ),
        )
      end
    end

    # Legate's keys: `grants.net` and `grants.ambient` (LEGATE.md §7),
    # and the per-call limits.
    class PolicySection < ::Adjutant::PolicySection
      NET_KEYS     = {"methods", "redirect_headers", "hosts"}
      AMBIENT_KEYS = {"env"}

      def name : String
        "legate"
      end

      def grant_keys : Array(String)
        %w[net ambient]
      end

      def limit_keys : Array(String)
        %w[read_limit fetch_limit url_limit stream_limit]
      end

      def load(grants : YamlPolicy::Mapping?, limits : YamlPolicy::Mapping?) : ::Adjutant::PolicyShare
        net = YamlPolicy.section(grants, "net", "grants.net", NET_KEYS)
        ambient = YamlPolicy.section(grants, "ambient", "grants.ambient", AMBIENT_KEYS)
        PolicyShare.new(
          net_rules: YamlPolicy.list(net, "hosts", "grants.net.hosts").map { |entry| NetRule.from_yaml_node(entry) },
          net_methods: YamlPolicy.strings(net, "methods", "grants.net.methods").map(&.downcase),
          net_redirect_headers: YamlPolicy.strings(net, "redirect_headers", "grants.net.redirect_headers"),
          ambient_env: YamlPolicy.strings(ambient, "env", "grants.ambient.env"),
          read_limit: YamlPolicy.size(limits, "read_limit") || Limits::DEFAULT_READ_LIMIT,
          fetch_limit: YamlPolicy.size(limits, "fetch_limit") || Limits::DEFAULT_FETCH_LIMIT,
          url_limit: YamlPolicy.size(limits, "url_limit") || Limits::DEFAULT_URL_LIMIT,
          stream_limit: YamlPolicy.size(limits, "stream_limit") || Limits::DEFAULT_STREAM_LIMIT,
        )
      end
    end
  end
end
