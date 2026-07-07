require "./risk_profile"

module Adjutant
  # A native function paired with its static RiskProfile.
  #
  # This is the single representation for any callable implemented in
  # Crystal rather than script code — currently functions installed via
  # Interpreter#define_native (including those loaded by ScriptModules
  # through ModuleRegistry). Planned: RubyClass native methods for base
  # types (String, Array, Integer, ...) will use the same wrapper, so a
  # risk-manifest walker has exactly one place to look regardless of
  # whether a call resolves to a required module's function or a base
  # type's method.
  #
  # Defaults to RiskProfile.none — most native functions are pure.
  struct NativeCallable
    getter func : NativeFunc
    getter risk : RiskProfile

    def initialize(@func : NativeFunc, @risk : RiskProfile = RiskProfile.none)
    end

    def call(args : Array(Value), blk : ScriptProc?, ctx : NativeCallContext) : Value
      @func.call(args, blk, ctx)
    end
  end
end
