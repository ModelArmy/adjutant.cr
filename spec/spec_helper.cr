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

  # A minimal but real NativeCallContext for specs that call a
  # NativeCallable directly (bypassing VM#dispatch_call/the real VM
  # entirely) — used where a test wants to exercise a single native
  # method in isolation rather than a full interp.eval. Shared across
  # spec files since every implementation needs identical behavior;
  # previously duplicated verbatim in ruby_class_native_methods_spec.cr
  # and native_singleton_spec.cr.
  class FakeContext
    include NativeCallContext

    def initialize(@filename : String = "<spec>", @line : Int32 = 0)
    end

    def invoke(proc : ScriptProc, args : Array(Value)) : Value
      Value.nil_value
    end

    # Real, not a stub — a direct-NativeCallable test that exercises a
    # method relying on == (e.g. Array#include?) needs actual
    # comparison semantics, not just a type-checking placeholder.
    def values_equal?(a : Value, b : Value) : Bool
      a == b
    end

    # Real, mirroring VM#compare_op's own int/float/string cases —
    # same reasoning as values_equal? above (e.g. Range#include?/#each
    # need actual ordering, not a placeholder).
    def compare(a : Value, b : Value, op : Symbol) : Bool
      case
      when a.int? && b.int?
        case op
        when :<  then a.as_int < b.as_int
        when :<= then a.as_int <= b.as_int
        when :>  then a.as_int > b.as_int
        when :>= then a.as_int >= b.as_int
        else          false
        end
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        case op
        when :<  then fa < fb
        when :<= then fa <= fb
        when :>  then fa > fb
        when :>= then fa >= fb
        else          false
        end
      when a.string? && b.string?
        case op
        when :<  then a.as_string < b.as_string
        when :<= then a.as_string <= b.as_string
        when :>  then a.as_string > b.as_string
        when :>= then a.as_string >= b.as_string
        else          false
        end
      else
        false
      end
    end

    # No-op — these direct-NativeCallable tests call a NativeCallable
    # directly, so there's no real VM here to dispatch a by-name call
    # through. A spec that needs real call_method behavior should go
    # through the real VM instead (interp.eval), the way
    # risk_flow_enforcement_spec.cr does for declare_sensitivity.
    def call_method(recv : Value, name : String, args : Array(Value)) : Value
      Value.nil_value
    end

    # No-op — these direct-NativeCallable tests don't exercise risk
    # flow enforcement, just method dispatch. See
    # risk_flow_enforcement_spec.cr for real declare_sensitivity
    # coverage, which goes through the actual VM.
    def declare_sensitivity(tag : RiskTag, kind : ProvenanceKind, origin : String,
                            sensitivity : Sensitivity? = nil) : Nil
    end
  end
end
