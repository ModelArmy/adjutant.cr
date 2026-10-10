require "./policy_yaml"
require "./resource_limits"

module Adjutant
  # What one PolicySection parsed from its keys.
  abstract class PolicyShare
  end

  # A claim on keys under a policy document's `grants:` and `limits:`,
  # with the parser for them. Core and each effect provider have one.
  # `Policy.from_yaml` refuses a key no section claims, and refuses two
  # sections claiming one key before it reads the document.
  abstract class PolicySection
    # Who claims the keys, as messages name it.
    abstract def name : String

    abstract def grant_keys : Array(String)
    abstract def limit_keys : Array(String)

    # This section's share of the document. `grants` and `limits` hold
    # only its own keys, and are nil when the document gives none.
    abstract def load(grants : YamlPolicy::Mapping?, limits : YamlPolicy::Mapping?) : PolicyShare
  end

  # Core's share of a policy: filesystem roots and per-run budgets.
  class CorePolicyShare < PolicyShare
    getter read_roots : Array(String)
    getter write_roots : Array(String)
    getter delete_roots : Array(String)
    getter limits : ResourceLimits

    def initialize(@read_roots, @write_roots, @delete_roots, @limits)
    end
  end

  # Core's keys: `grants.read`, `.write` and `.delete`, each a list of
  # `roots`, and the per-run budgets with `max_open_streams`.
  class CorePolicySection < PolicySection
    def name : String
      "core"
    end

    def grant_keys : Array(String)
      %w[read write delete]
    end

    def limit_keys : Array(String)
      %w[max_open_streams memory wall_clock total_read total_write max_asks]
    end

    def load(grants : YamlPolicy::Mapping?, limits : YamlPolicy::Mapping?) : PolicyShare
      CorePolicyShare.new(
        roots_of(grants, "read"), roots_of(grants, "write"), roots_of(grants, "delete"),
        ResourceLimits.new(
          max_open_streams: YamlPolicy.count(limits, "max_open_streams") || ResourceLimits::DEFAULT_MAX_OPEN_STREAMS,
          memory: YamlPolicy.size(limits, "memory") || ResourceLimits::DEFAULT_MEMORY,
          wall_clock: YamlPolicy.seconds(limits, "wall_clock") || ResourceLimits::DEFAULT_WALL_CLOCK,
          total_read: YamlPolicy.size(limits, "total_read") || ResourceLimits::DEFAULT_TOTAL_READ,
          total_write: YamlPolicy.size(limits, "total_write") || ResourceLimits::DEFAULT_TOTAL_WRITE,
          max_asks: YamlPolicy.count(limits, "max_asks") || ResourceLimits::DEFAULT_MAX_ASKS,
        ),
      )
    end

    private def roots_of(grants : YamlPolicy::Mapping?, category : String) : Array(String)
      section = YamlPolicy.section(grants, category, "grants.#{category}", {"roots"})
      YamlPolicy.strings(section, "roots", "grants.#{category}.roots")
    end
  end
end
