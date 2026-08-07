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

  # Helper: parse source into a full Body — shared across every parser
  # spec file (previously local to the single, now-split parser_spec.cr;
  # moved here so each split-out file can use it without redefining it,
  # which would be a duplicate top-level method across files compiled
  # into the same module).
  private def self.parse(source : String) : Body
    Parser.new(source).parse
  end

  # Helper: parse source and return just its first top-level statement —
  # for specs asserting on a single expression/statement's AST shape
  # rather than a whole program. Moved here alongside `parse` for the
  # same reason.
  private def self.parse_expr(source : String) : Node
    body = parse(source)
    body.stmts.first
  end

  # Shared symbol table for compiler specs — simulates multiple scripts
  # compiled against the same interpreter instance. Moved here alongside
  # `compile`/`ops`/`def_proc_chunk` for the same reason as `parse`/
  # `parse_expr` above — was local to the single, now-split
  # compiler_spec.cr.
  COMPILER_SPEC_SYMBOLS = SymbolTable.new

  # Helper: parse source and compile to a Chunk.
  private def self.compile(source : String) : Chunk
    body = Parser.new(source).parse
    chunk, _local_count = Compiler.compile(body, COMPILER_SPEC_SYMBOLS)
    chunk
  end

  # Helper: return just the opcode sequence (excluding Const setup noise).
  private def self.ops(source : String) : Array(Op)
    compile(source).code.map(&.op)
  end

  # Helper: compile source whose LAST top-level statement is expected to
  # be a `def`, call literal block, `for`, or lambda assignment, and
  # return the compiled PROC BODY's own chunk (not the outer chunk) —
  # i.e. what Compiler.compile_proc actually produced for it, including
  # any default-value prologue emit_default_prologue emitted. Finds the
  # nearest Op::MakeProc in the outer chunk and follows its const-pool
  # index into the ScriptProc it pushes.
  private def self.def_proc_chunk(source : String) : Chunk
    chunk = compile(source)
    make_proc = chunk.code.reverse.find { |inst| inst.op == Op::MakeProc } ||
                raise "no Op::MakeProc in compiled output for #{source.inspect}"
    chunk.consts[make_proc.c].as_proc.chunk
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

    # Both accept and ignore their args — this stub never actually
    # invokes anything; it only exists to satisfy NativeCallContext's
    # interface for direct-NativeCallable tests that don't exercise
    # real block/lambda invocation.
    def invoke(proc : ScriptProc, args : Array(Value)) : Value
      Value.nil_value
    end

    def invoke_proc(proc_obj : RubyObject, args : Array(Value)) : Value
      Value.nil_value
    end

    # Delegates to ValueOps (value_ops.cr) — the same VM-independent
    # logic Op::Eq/Op::Lt/etc. use, and the only implementation now;
    # this used to be a third hand-duplicated copy of compare_op's
    # int/float/string cases, kept in sync by hand. ValueOps existing
    # as a standalone module (no VM reference needed for compare/
    # equal?, which never raise) is what makes this a one-line
    # delegation instead of another copy.
    def values_equal?(a : Value, b : Value) : Bool
      ValueOps.equal?(a, b)
    end

    def compare(a : Value, b : Value, op : Symbol) : Bool
      ValueOps.compare(a, b, op)
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
