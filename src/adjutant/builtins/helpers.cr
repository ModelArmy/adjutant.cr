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
  private macro __define_mapped_methods(cls, interp, self_as, return_as, methods, crystal_methods = nil)
    {% for method, index in methods %}
    define({{cls}}, {{interp}}, {{method.stringify}}) do |args|
      val = args.first.as_{{self_as}}
      Adjutant::Value.{{return_as}}(val.{{crystal_methods ? crystal_methods[index] : method}})
    end
    {% end %}
  end

  # Macro to define a getter method for `name` property, with `default` which can be
  # an expression that uses `obj` for the instance
  private macro __define_getter(cls, interp, name, default = Value.nil_value)
    define({{cls}}, {{interp}}, {{name}}) do |args|
      obj = args.first.as_robject
      name_sym = {{interp}}.symbols.intern({{name}})
      obj.ivars[name_sym.value]? || {{default}}
    end
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

  # Registers a native singleton method on a builtin RubyClass, keyed by its
  # interned symbol id. `risk` defaults to RiskProfile.none since most
  # builtin methods (arithmetic helpers aside, which don't go through
  # this path at all — see integer.cr) are pure; pass an explicit
  # profile for anything with real side effects (none exist yet among
  # the base types, but e.g. a future File/IO type would).
  def self.define_singleton(cls : Adjutant::RubyClass, interp : Adjutant::Interpreter, name : String,
                            risk : Adjutant::RiskProfile = Adjutant::RiskProfile.none,
                            &block : Array(Adjutant::Value), Adjutant::ScriptProc?, Adjutant::NativeCallContext -> Adjutant::Value) : Nil
    sym_id = interp.symbols.intern(name).value
    cls.define_native_singleton_method(sym_id, risk) { |args, blk, ncc| block.call(args, blk, ncc) }
  end
end
