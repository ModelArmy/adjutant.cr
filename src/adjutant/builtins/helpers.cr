require "../ruby_class"
require "../native_callable"
require "../risk_profile"

module Adjutant::Builtins
  # Registers a native method on a builtin RubyClass, keyed by its
  # interned symbol id. `risk` defaults to RiskProfile.none since most
  # builtin methods (arithmetic helpers aside, which don't go through
  # this path at all — see integer.cr) are pure; pass an explicit
  # profile for anything with real side effects (none exist yet among
  # the base types, but e.g. a future File/IO type would).
  def self.define(cls : Adjutant::RubyClass, interp : Adjutant::Interpreter, name : String,
                  risk : Adjutant::RiskProfile = Adjutant::RiskProfile.none,
                  &block : Array(Adjutant::Value), Adjutant::ScriptProc?, Adjutant::NativeCallContext -> Adjutant::Value) : Nil
    sym_id = interp.symbols.intern(name).value
    cls.define_native_method(sym_id, risk) { |args, blk, ncc| block.call(args, blk, ncc) }
  end
end
