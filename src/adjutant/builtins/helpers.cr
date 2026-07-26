require "../ruby_class"
require "../native_callable"
require "../risk_profile"

module Adjutant::Builtins
  # Use this macro to define native methods that take no arguments, do some
  # calculation with their data and return the result
  # - `arg_as` is the type suffix in `Value#as_XXX` methods
  # - `return_as` is the type suffix in `Value#XXX(...)` constructor methods
  # - `methods` is an array of native methods
  # - `crystal_methods` is an optional array to use when the defined name doesn't match Crystal's stdlib method name
  private macro map_self_calc_methods(arg_as, return_as, methods, crystal_methods = nil)
    {% for method, index in methods %}
    define(cls, interp, {{method.stringify}}) do |args|
      val = args.first.as_{{arg_as}}
      Adjutant::Value.{{return_as}}(val.{{crystal_methods ? crystal_methods[index] : method}})
    end
    {% end %}
  end

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
