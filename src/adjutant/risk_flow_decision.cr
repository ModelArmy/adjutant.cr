require "./risk_flow_policy"
require "./risk_flow_label"
require "./risk_profile"

module Adjutant
  # One (rule, tag) pair that contributed to a RiskFlowAction::Ask
  # decision — the specific policy rule that fired, paired with the
  # specific tainted value's provenance that triggered it. A call can
  # have several tainted arguments, each independently matching its own
  # rule (e.g. one arg tainted by a sensitive file, another by an
  # unfamiliar host) — RiskFlowMatch keeps each cause paired with its
  # own consequence rather than flattening them into a set of rules and
  # a set of tags with no way to tell which caused which.
  struct RiskFlowMatch
    getter rule : RiskFlowRule
    getter tag : ProvenanceTag

    def initialize(@rule : RiskFlowRule, @tag : ProvenanceTag)
    end
  end

  # What Adjutant asks the embedding agent to decide when a risky call's
  # tainted arguments trigger RiskFlowAction::Ask. Self-contained: an
  # agent should be able to build a real prompt/UI from this alone,
  # without reaching back into VM internals.
  #
  # Deliberately does NOT include the call's raw arguments — see
  # research/IFC_DESIGN.md's enforcement design notes: `matches` already
  # carries the specific tainted value(s) that caused the escalation
  # (each as a ProvenanceTag with a concrete origin), which is more
  # precise than positional args (no way to tell which arg was
  # "the dangerous one" without guessing) and avoids rendering
  # potentially large/irrelevant argument values into every prompt.
  struct RiskFlowDecisionRequest
    getter call_name : String
    getter risk : RiskProfile
    # Sorted worst-first: RiskFlowAction (Reject > Ask), then
    # Sensitivity (High > Elevated), stable beyond that (ties preserve
    # discovery order) — so `matches.first` is a reasonable "the primary
    # reason" for an agent that doesn't want to enumerate all of them,
    # while `matches` itself never discards information Adjutant has.
    getter matches : Array(RiskFlowMatch)
    getter filename : String
    getter line : Int32

    def initialize(@call_name : String, @risk : RiskProfile, @matches : Array(RiskFlowMatch),
                   @filename : String, @line : Int32)
    end
  end

  # The embedding agent's answer to a RiskFlowDecisionRequest — Allow
  # lets the call proceed, Reject blocks it (raising RiskFlowRejectedError
  # into the script, catchable like any other StandardError). No richer
  # response type (e.g. rewriting arguments) — out of scope for now, see
  # research/IFC_DESIGN.md.
  enum RiskFlowDecision
    Allow
    Reject
  end

  # Base for the script-visible risk-flow exception hierarchy. Scripts
  # can `rescue RiskFlowPolicyError` to catch any risk-flow rejection
  # uniformly, or `rescue RiskFlowRejectedError` (currently the only
  # subclass) for the same effect. Distinct from
  # AmbiguousRiskFlowPolicyError (risk_flow_policy.cr), which is NOT
  # script-visible — see that class's doc comment for the script-visible
  # vs. Adjutant/agent-only distinction this follows.
  #
  # This Crystal-level class is what VM/Interpreter code raises and
  # catches internally; the script-visible object scripts actually
  # `rescue` is a RubyObject wrapping it, same pattern as every other
  # script-raised error in the bootstrapped StandardError hierarchy.
  class RiskFlowPolicyError < Exception
  end

  # Raised when a risk flow decision blocks a call — either because a
  # matched RiskFlowRule's action was Reject, or because the configured
  # on_risk_flow_decision callback returned RiskFlowDecision::Reject for
  # an Ask. The script (and the LLM that authored it, seeing this on the
  # next turn either from an uncaught-exception eval failure or from a
  # `rescue`d, deliberately-concise report) does not need to know which
  # of those two cases occurred — from the script's point of view, a
  # risky call it tried to make simply didn't happen. See
  # research/IFC_DESIGN.md's enforcement design notes.
  class RiskFlowRejectedError < RiskFlowPolicyError
    getter request : RiskFlowDecisionRequest

    def initialize(@request : RiskFlowDecisionRequest)
      reason = @request.matches.first?.try { |match| "#{match.rule.tag} (#{match.tag})" } || @request.call_name
      super("risk flow policy rejected #{@request.call_name}: #{reason}")
    end
  end
end
