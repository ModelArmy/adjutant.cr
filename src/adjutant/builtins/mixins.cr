require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Registers `include` and `extend` on Module, so they're callable
  # bare in both class and module bodies: a class's class is Class,
  # whose superclass is Module.
  def self.register_module_methods(mod_cls : Adjutant::RubyClass, interp : Adjutant::Interpreter) : Nil
    define(mod_cls, interp, "include", arity: 1) do |args, _blk, ncc|
      # Called bare in a class or module body, so there's no receiver
      # in `args`: self is the class, and `args.first` is the module.
      including = ncc.self_val.as_rclass
      including.include_module(module_argument(args.first, ncc))
      ncc.self_val
    end

    define(mod_cls, interp, "extend", arity: 1) do |args, _blk, ncc|
      # As `include`, into `extended_modules`.
      extending = ncc.self_val.as_rclass
      extending.extend_module(module_argument(args.first, ncc))
      ncc.self_val
    end
  end

  # `include` and `extend`'s argument as a module; anything else, a
  # class included, raises R055 (TypeError), as in Ruby.
  private def self.module_argument(arg : Adjutant::Value, ncc : Adjutant::NativeCallContext) : Adjutant::RubyClass
    if (mod = arg.as_rclass?) && mod.is_module?
      return mod
    end
    type = arg.rclass? ? "Class" : builtin_type_name(arg)
    ncc.raise_error("R055", {"type" => type}, "TypeError")
  end
end
