require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Registers `include` and `extend` on Module, so they're callable
  # bare in both class and module bodies: a class's class is Class,
  # whose superclass is Module.
  def self.register_module_methods(mod_cls : Adjutant::RubyClass, interp : Adjutant::Interpreter) : Nil
    define(mod_cls, interp, "include") do |args, _blk, ncc|
      # Called bare in a class or module body, so there's no receiver
      # in `args`: self is the class, and `args.first` is the module.
      # The argument isn't checked to be a module: a class is
      # accepted, where Ruby raises TypeError.
      including = ncc.self_val.as_rclass
      mod = args.first.as_rclass
      including.include_module(mod)
      ncc.self_val
    end

    define(mod_cls, interp, "extend") do |args, _blk, ncc|
      # As `include`, into `extended_modules`.
      extending = ncc.self_val.as_rclass
      mod = args.first.as_rclass
      extending.extend_module(mod)
      ncc.self_val
    end
  end
end
