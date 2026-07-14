require "./risk_flow_policy"
require "./risk_flow_label"
require "./risk_profile"

module Adjutant
  # One (rule, tag) pair that contributed to a non-Allow decision — the
  # specific policy rule that fired (nil when the action came from
  # RiskFlowPolicy.reject_all rather than a specific RiskFlowRule — see
  # RiskFlowPolicy#action_for), paired with the specific tainted value's
  # provenance that triggered it. A call can have several tainted
  # arguments, each independently matching its own rule (e.g. one arg
  # tainted by a sensitive file, another by an unfamiliar host) —
  # RiskFlowMatch keeps each cause paired with its own consequence
  # rather than flattening them into a set of rules and a set of tags
  # with no way to tell which caused which.
  struct RiskFlowMatch
    getter action : RiskFlowAction
    getter rule : RiskFlowRule?
    getter tag : ProvenanceTag

    def initialize(@action : RiskFlowAction, @rule : RiskFlowRule?, @tag : ProvenanceTag)
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
  # lets the call proceed, Reject blocks it. Blocking raises a
  # script-catchable error (script-visible class: RiskFlowRejectedError,
  # bootstrapped under StandardError by
  # Interpreter#bootstrap_error_classes) the same way every other
  # script-raised error works: the Crystal-level exception is always
  # RuntimeError (vm.cr), with a RubyObject of the right builtin class
  # attached via `error_value` — there is no separate Crystal-level
  # RiskFlowPolicyError/RiskFlowRejectedError exception hierarchy, since
  # the dispatch loop's rescue-and-unwind machinery only catches
  # `RuntimeError` specifically. No richer response type (e.g.
  # rewriting arguments) — out of scope for now, see
  # research/IFC_DESIGN.md.
  enum RiskFlowDecision
    Allow
    Reject
  end
end
