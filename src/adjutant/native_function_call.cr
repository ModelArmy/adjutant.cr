require "./native_call_context"

module Adjutant
  # The concrete, VM-backed implementation of NativeCallContext — see
  # that module for the documented, public-facing contract every
  # method here fulfills. This struct itself is internal: constructed
  # by VM#call_native for the duration of a single native call, handed
  # to the native function as `ncc`, and discarded once that call
  # returns. Every method here is a thin, one-line delegation to the
  # VM that actually owns the behavior (`@vm.invoke`, `@vm.call_method`,
  # ...) — this struct's only real job is bundling the per-call context
  # (filename/line/kwargs/the native function's own name, for
  # diagnostics) alongside a VM reference, not implementing any of
  # NativeCallContext's actual logic itself.
  struct NativeFunctionCall
    include NativeCallContext

    @vm : VM
    @callable : NativeCallable
    @name : String

    protected def initialize(@vm, @callable, @filename, @line, @name, @kwargs : Hash(String, Value)? = nil); end

    protected def call(args : Array(Value), blk : ScriptProc?) : Value
      @callable.call(args, blk, self)
    end

    # ---- CallContext
    def invoke(proc : ScriptProc, args : Array(Value)) : Value
      @vm.invoke(proc, args)
    end

    def self_val : Value
      @vm.current_self_val
    end

    def invoke_proc(proc_obj : RubyObject, args : Array(Value)) : Value
      @vm.invoke_proc(proc_obj, args)
    end

    def wrap_block_as_proc(blk : ScriptProc) : Value
      @vm.wrap_block_as_proc(blk, filename, line)
    end

    def values_equal?(a : Value, b : Value) : Bool
      @vm.values_equal?(a, b)
    end

    def compare(a : Value, b : Value, op : Symbol) : Bool
      @vm.compare(a, b, op, filename, line)
    end

    def add(a : Value, b : Value) : Value
      @vm.add(a, b)
    end

    def call_method(recv : Value, name : String, args : Array(Value)) : Value
      @vm.call_method(recv, name, args, filename, line)
    end

    def guard_rendering(obj_id : UInt64, cycle_result : String, & : -> String) : String
      @vm.guard_rendering(obj_id, cycle_result) { yield }
    end

    def declare_sensitivity(tag : RiskTag, kind : ProvenanceKind, origin : String,
                            sensitivity : Sensitivity? = nil) : RiskFlowLabel?
      @vm.declare_sensitivity(tag, kind, origin, @name, filename, line, sensitivity)
    end

    def raise_error(code : String, data : Hash(String, String) = {} of String => String,
                    error_class : String = "RuntimeError") : NoReturn
      @vm.raise_native_error(code, data, error_class, filename, line)
    end

    def raise_error_class(message : String, error_class : RubyClass,
                          attributes : Hash(String, Value)? = nil) : NoReturn
      @vm.raise_native_error_class(message, error_class, filename, line, attributes)
    end
  end
end
