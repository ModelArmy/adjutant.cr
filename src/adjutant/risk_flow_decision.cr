require "./authority"
require "./risk_flow_policy"
require "./risk_flow_label"
require "./risk_profile"

module Adjutant
  # One reason a call was escalated: the rule that fired (nil when the
  # policy is `reject_all`) paired with the tag that triggered it. A
  # call with several labelled arguments gets one match per cause.
  struct RiskFlowMatch
    getter action : RiskFlowAction
    getter rule : RiskFlowRule?
    getter tag : ProvenanceTag

    def initialize(@action : RiskFlowAction, @rule : RiskFlowRule?, @tag : ProvenanceTag)
    end
  end

  # What the host is asked when a call's labelled arguments trigger
  # Ask; enough to build a prompt without the VM. The raw arguments
  # are left out: `matches` names the labelled values that caused it,
  # and arguments can be large.
  struct RiskFlowDecisionRequest
    getter call_name : String
    # What the call does, for display. `authority`, below, is what the
    # policy matched on; a prompt may need both.
    getter risk : RiskProfile
    getter authorities : Set(Authority)
    # Worst first (Reject before Ask, then High before Elevated), in
    # discovery order otherwise, so `matches.first` is the main
    # reason.
    getter matches : Array(RiskFlowMatch)
    getter filename : String
    getter line : Int32

    def initialize(@call_name : String, @risk : RiskProfile, @authorities : Set(Authority),
                   @matches : Array(RiskFlowMatch), @filename : String, @line : Int32)
    end
  end

  # The host's answer: Allow lets the call proceed; Reject raises
  # RiskFlowRejectedError, which the script can rescue.
  enum RiskFlowDecision
    Allow
    Reject
  end
end
