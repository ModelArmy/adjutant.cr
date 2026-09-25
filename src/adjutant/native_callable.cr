require "./authority"
require "./risk_profile"

module Adjutant
  # A function implemented in Crystal, with what it does (`risk`),
  # what it needs permission for (`authorities`) and which keywords it
  # accepts. Every native function and every native method on a class
  # is one.
  struct NativeCallable
    getter func : NativeFunc
    getter risk : RiskProfile

    # The authorities this call is a sink for. `VM#check_risk_flow`
    # checks labelled arguments against each one before the call
    # runs; an empty set, the default, skips the check. Separate from
    # `risk`: a move needs Delete and Write authority but destroys
    # nothing.
    getter authorities : Set(Authority)

    # Keyword names the call accepts; any other keyword raises R012.
    # Empty, the default, accepts none. Names only: the function reads
    # `NativeCallContext#kwargs` and supplies its own defaults.
    getter kwarg_names : Set(String)

    def initialize(@func : NativeFunc, @risk : RiskProfile = RiskProfile.none,
                   @kwarg_names : Set(String) = Set(String).new,
                   @authorities : Set(Authority) = Set(Authority).new)
    end

    def call(args : Array(Value), blk : ScriptProc?, ctx : NativeCallContext) : Value
      @func.call(args, blk, ctx)
    end
  end
end
