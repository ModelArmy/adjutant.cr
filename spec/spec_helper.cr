require "spec"
require "../src/adjutant"

module Adjutant
  # Shared test default: reject_all, since most specs aren't testing IFC
  # behavior and never label any values — action_for short-circuits to
  # Allow for Sensitivity::None before reject_all_flows is even
  # consulted, so this has no effect on specs that don't attach labels.
  # The callback here should never actually be invoked by specs using
  # this default; it raises if it somehow is, to make an unexpected
  # Ask fail loudly rather than silently deciding something on the
  # spec's behalf.
  TEST_REJECT_ALL_POLICY       = RiskFlowPolicy.reject_all
  TEST_UNEXPECTED_ASK_CALLBACK = ->(req : RiskFlowDecisionRequest) : RiskFlowDecision {
    raise "unexpected RiskFlowDecisionRequest in a spec not testing risk flow decisions: #{req.call_name}"
  }

  # Helper: create an interpreter with a capturing effect handler.
  private def self.make_interp(
    limits : ExecutionLimits = ExecutionLimits.new,
    risk_flow_policy : RiskFlowPolicy = TEST_REJECT_ALL_POLICY,
    on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision = TEST_UNEXPECTED_ASK_CALLBACK,
  ) : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(
      risk_flow_policy: risk_flow_policy,
      on_risk_flow_decision: on_risk_flow_decision,
      effect: ef,
      limits: limits,
    )
    {interp, ef}
  end

  # Helper: create an interpreter and register a module.
  private def self.make_interp_with_module(name : String, &block : Interpreter -> Nil) : {Interpreter, TestEffectHandler}
    interp, ef = make_interp
    interp.modules.register(name) { |i| block.call(i) }
    {interp, ef}
  end

  # Helper: eval source and return the result value.
  private def self.eval(source : String) : Value
    interp, _ = make_interp
    interp.eval(source)
  end
end
