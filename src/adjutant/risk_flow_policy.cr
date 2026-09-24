require "json"
require "./authority"
require "./risk_profile"
require "./diagnostic"

module Adjutant
  # What a matched risk-flow rule does with a call:
  #
  #   Allow:  the call proceeds.
  #   Ask:    the host's `on_risk_flow_decision` callback decides.
  #   Reject: the call is refused without asking.
  #
  # See research/IFC_DESIGN.md, "Risk flow policy".
  enum RiskFlowAction
    Allow
    Ask
    Reject
  end

  # How `SensitivityPattern#pattern` is matched.
  enum PatternType
    Exact
    Regex
  end

  # One rule assigning a sensitivity to subjects of a kind whose
  # origin matches `pattern`, consulted when data is tagged.
  # Specificity is stated by `priority`, never inferred from the
  # pattern or its position: hosts get more specific leftwards, paths
  # rightwards.
  struct SensitivityPattern
    include JSON::Serializable

    getter kind : ProvenanceKind
    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String
    getter priority : Int32
    getter sensitivity : Sensitivity

    def initialize(@kind : ProvenanceKind, @pattern : String, @priority : Int32,
                   @sensitivity : Sensitivity, @pattern_type : PatternType = PatternType::Exact)
    end

    def matches?(origin : String) : Bool
      case pattern_type
      in .exact? then pattern == origin
      in .regex? then Regex.new(pattern).matches?(origin)
      end
    end
  end

  # One rule mapping data of `sensitivity` reaching a sink with
  # `authority` to an action. `Sensitivity::None` always allows, so
  # rules only cover Elevated and High. Keyed on Authority, not
  # Effect: the question is what the call may do.
  struct RiskFlowRule
    include JSON::Serializable

    getter authority : Authority
    getter sensitivity : Sensitivity
    getter action : RiskFlowAction

    def initialize(@authority : Authority, @sensitivity : Sensitivity, @action : RiskFlowAction)
    end
  end

  # Raised when two sensitivity patterns match the same subject at the
  # same top priority: the policy's priorities collide, and picking
  # one would hide that. A Crystal exception, not script-visible: a
  # broken policy is the host's configuration error, and a script must
  # not be able to rescue past it.
  class AmbiguousRiskFlowPolicyError < Exception
    getter diagnostic : Diagnostic?

    def initialize(diagnostic : Diagnostic)
      @diagnostic = diagnostic
      super(diagnostic.to_line)
    end

    def initialize(message : String)
      @diagnostic = nil
      super(message)
    end
  end

  # A risk-flow policy: sensitivity patterns and action rules. The
  # host builds it and passes it to the Interpreter; Adjutant never
  # reads one from disk. There is no allow-everything default: a host
  # that wants no assessment must pass `RiskFlowPolicy.reject_all` or
  # a real policy.
  class RiskFlowPolicy
    include JSON::Serializable

    getter sensitivity_patterns : Array(SensitivityPattern)
    getter risk_flow_rules : Array(RiskFlowRule)

    # Rejects every non-None sensitivity whatever the rules say; see
    # `.reject_all`. Never loaded from JSON.
    @[JSON::Field(ignore: true)]
    getter? reject_all_flows : Bool = false

    def initialize(@sensitivity_patterns : Array(SensitivityPattern) = [] of SensitivityPattern,
                   @risk_flow_rules : Array(RiskFlowRule) = [] of RiskFlowRule,
                   @reject_all_flows : Bool = false)
    end

    # A policy that rejects every flow of sensitive data, including
    # through authorities added later.
    def self.reject_all : RiskFlowPolicy
      new(reject_all_flows: true)
    end

    # The sensitivity of `origin`: the highest-priority matching
    # pattern's, or None if nothing matches. Raises
    # AmbiguousRiskFlowPolicyError on a tie at the top priority.
    def sensitivity_for(kind : ProvenanceKind, origin : String) : Sensitivity
      matches = sensitivity_patterns.select { |pattern| pattern.kind == kind && pattern.matches?(origin) }
      return Sensitivity::None if matches.empty?

      top_priority = matches.max_of(&.priority)
      top = matches.select { |pattern| pattern.priority == top_priority }
      if top.size > 1
        raise AmbiguousRiskFlowPolicyError.new(
          Diagnostic.new(
            code: "H003",
            data: {
              "count"    => top.size.to_s,
              "priority" => top_priority.to_s,
              "target"   => "#{kind}:#{origin}",
            }
          )
        )
      end
      top.first.sensitivity
    end

    # The action for `sensitivity` reaching a sink with `authority`,
    # with the rule that decided it (nil for a default):
    #
    #   1. None sensitivity: Allow, always.
    #   2. `reject_all_flows`: Reject.
    #   3. A matching rule: its action.
    #   4. Otherwise Allow: an authority with no rules is not governed
    #      by the policy.
    def action_for(authority : Authority, sensitivity : Sensitivity) : {RiskFlowAction, RiskFlowRule?}
      return {RiskFlowAction::Allow, nil} if sensitivity.none?
      return {RiskFlowAction::Reject, nil} if reject_all_flows?
      matched = risk_flow_rules.find { |rule| rule.authority == authority && rule.sensitivity == sensitivity }
      {matched.try(&.action) || RiskFlowAction::Allow, matched}
    end
  end
end
