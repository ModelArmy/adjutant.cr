require "json"
require "./risk_profile"

module Adjutant
  # How a matched risk flow rule resolves a risky call.
  #
  # Allow: proceed, no interruption.
  # Ask: pause and surface the concrete flow to the agent/user for a
  #   live decision — requires an actual prompting mechanism, added in
  #   piece 4 (enforcement); not wired up yet.
  # Reject: policy has already decided no, unconditionally — no prompt.
  #   For organizational rules that should never be silently approved
  #   regardless of who's asked, and for unattended execution where
  #   there's no one to ask.
  #
  # See research/IFC_DESIGN.md's "Risk flow policy (piece 3)" section.
  enum RiskFlowAction
    Allow
    Ask
    Reject
  end

  # How SensitivityPattern#pattern is interpreted.
  enum PatternType
    Exact
    Regex
  end

  # A single origin → sensitivity rule. Matched against a ProvenanceTag's
  # (kind, origin) at tag-creation time (e.g. a File IO module checking
  # the path it just opened). Specificity is stated explicitly via
  # `priority` — not inferred from pattern syntax or array position; see
  # the design doc for why (hostnames get more specific reading left,
  # paths reading right, so no single syntax-driven rule generalizes).
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

  # A single (RiskTag, Sensitivity) → RiskFlowAction rule, consulted at the
  # risk flow check. Sensitivity::None always allows regardless of table
  # contents (see RiskFlowPolicy#action_for) — rows here only need to cover
  # Elevated/High cases that should escalate above the default.
  struct RiskFlowRule
    include JSON::Serializable

    getter tag : RiskTag
    getter sensitivity : Sensitivity
    getter action : RiskFlowAction

    def initialize(@tag : RiskTag, @sensitivity : Sensitivity, @action : RiskFlowAction)
    end
  end

  # Raised when two SensitivityPattern rules match the same (kind,
  # origin) at the same top priority — ambiguous policy, not resolved
  # silently. See research/IFC_DESIGN.md's "Pattern matching for
  # sensitivity lookup" section for why this is a hard error rather than
  # picking one arbitrarily: with explicit priorities, a tie means the
  # policy author's priorities actually collide, not that Adjutant
  # failed to compute specificity.
  #
  # NOT script-visible — a plain Crystal Exception, not a StandardError
  # subclass in the bootstrapped script exception hierarchy. A malformed
  # policy is an agent/embedder configuration problem, not something a
  # running script did wrong; a script must not be able to `rescue` its
  # way past a broken policy any more than it can catch an internal
  # Adjutant bug. See research/IFC_DESIGN.md's enforcement design notes
  # for the general script-visible vs. Adjutant/agent-only distinction
  # this follows. The script-visible counterpart, RiskFlowRejectedError,
  # lives in risk_flow_decision.cr alongside RiskFlowDecisionRequest,
  # which it needs to carry.
  class AmbiguousRiskFlowPolicyError < Exception
  end

  # A single risk flow policy: sensitivity lookup rules plus risk flow
  # action rules. Loaded and owned by whatever embeds Adjutant (the
  # agent) — Adjutant itself never reads a policy path off disk; the
  # agent parses or constructs a RiskFlowPolicy and passes it to
  # Interpreter. See research/IFC_DESIGN.md's "Policy object" and "Risk
  # flow policy" sections.
  #
  # There is no bare `RiskFlowPolicy.new` default that means "allow
  # everything" — Adjutant does not silently permit risky calls just
  # because an embedder didn't think about IFC. An embedder who
  # genuinely wants no risk assessment must say so explicitly by
  # constructing `RiskFlowPolicy.reject_all` (safe default: reject
  # rather than allow) or a real policy — not by omission.
  class RiskFlowPolicy
    include JSON::Serializable

    getter sensitivity_patterns : Array(SensitivityPattern)
    getter risk_flow_rules : Array(RiskFlowRule)

    # When true, action_for always returns Reject for any non-None
    # sensitivity, regardless of risk_flow_rules — see .reject_all.
    # Not persisted via JSON: a loaded policy file is always a real
    # rule table, never this blanket mode.
    @[JSON::Field(ignore: true)]
    getter? reject_all_flows : Bool = false

    def initialize(@sensitivity_patterns : Array(SensitivityPattern) = [] of SensitivityPattern,
                   @risk_flow_rules : Array(RiskFlowRule) = [] of RiskFlowRule,
                   @reject_all_flows : Bool = false)
    end

    # A policy that rejects every risky call outright — no sensitivity
    # patterns or risk_flow_rules needed, and (unlike an exhaustive
    # generated rule table) never silently stops covering a RiskTag
    # that's added later. The explicit, safe-by-default choice for an
    # embedder who wants "no risk assessment" without accidentally
    # meaning "allow everything."
    def self.reject_all : RiskFlowPolicy
      new(reject_all_flows: true)
    end

    # origin → sensitivity lookup, consulted by native modules at
    # tag-creation time. Highest-priority match wins; a tie among
    # matches at the top priority raises AmbiguousRiskFlowPolicyError. No match
    # at all → Sensitivity::None.
    def sensitivity_for(kind : ProvenanceKind, origin : String) : Sensitivity
      matches = sensitivity_patterns.select { |pattern| pattern.kind == kind && pattern.matches?(origin) }
      return Sensitivity::None if matches.empty?

      top_priority = matches.max_of(&.priority)
      top = matches.select { |pattern| pattern.priority == top_priority }
      if top.size > 1
        raise AmbiguousRiskFlowPolicyError.new(
          "ambiguous risk flow policy: #{top.size} sensitivity_patterns rules tie at priority " \
          "#{top_priority} for #{kind}:#{origin}"
        )
      end
      top.first.sensitivity
    end

    # (RiskTag, Sensitivity) → action lookup, consulted at the risk flow
    # check. Sensitivity::None always allows regardless of table
    # contents — the universal default is not overridable by a rule,
    # only sensitivities above None can be. No matching rule for a
    # non-None sensitivity → Allow (a tag with no configured rows is
    # treated as not policy-relevant, not as an implicit escalation) —
    # unless reject_all_flows is set, in which case every non-None
    # sensitivity is Reject regardless of risk_flow_rules.
    #
    # Returns the RiskFlowRule that was matched, if any, alongside the
    # action — nil when the result came from a default (None
    # sensitivity, reject_all_flows, or no matching rule) rather than an
    # explicit rule. Callers building a RiskFlowMatch for a
    # RiskFlowDecisionRequest need the specific rule that fired, not
    # just the resulting action.
    def action_for(tag : RiskTag, sensitivity : Sensitivity) : {RiskFlowAction, RiskFlowRule?}
      return {RiskFlowAction::Allow, nil} if sensitivity.none?
      return {RiskFlowAction::Reject, nil} if reject_all_flows?
      matched = risk_flow_rules.find { |rule| rule.tag == tag && rule.sensitivity == sensitivity }
      {matched.try(&.action) || RiskFlowAction::Allow, matched}
    end
  end
end
