require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Define the various Exception-derived error classes and yield each one
  def self.bootstrap_exception_and_subclasses(interp : Interpreter, & : -> RubyClass) : Void
    yield exception = define_exception_class(interp)
    yield standard_error = RubyClass.new("StandardError", exception)
    yield RubyClass.new("RuntimeError", standard_error)
    yield RubyClass.new("TypeError", standard_error)
    yield RubyClass.new("ArgumentError", standard_error)
    yield RubyClass.new("ZeroDivisionError", standard_error)
    yield RubyClass.new("RegexpError", standard_error)
    yield name_error = define_name_error_class(interp, standard_error)
    yield RubyClass.new("NoMethodError", name_error)
    yield index_error = RubyClass.new("IndexError", standard_error)
    yield RubyClass.new("KeyError", index_error)
    yield range_error = RubyClass.new("RangeError", standard_error)
    yield RubyClass.new("FloatDomainError", range_error)

    # IFC related exceptions
    yield risk_flow_policy_error = RubyClass.new("RiskFlowPolicyError", standard_error)
    yield RubyClass.new("RiskFlowRejectedError", risk_flow_policy_error)
  end

  # Create and return a default Exception instance
  private def self.new_exception(interp : Interpreter, cls : RubyClass, args : Array(Value)) : RubyObject
    inst = RubyObject.new(cls)
    # skip first arg, should be `cls`
    if msg = args[1]?
      msg = Value.string(msg.to_s, msg.label) unless msg.string?
      msg_sym = interp.symbols.intern("message")
      inst.ivars[msg_sym.value] = msg
    end
    inst
  end

  # Define the Exception class with `message` property
  private def self.define_exception_class(interp : Interpreter) : RubyClass
    cls = RubyClass.new("Exception")

    define_singleton(cls, interp, "new") do |args|
      Value.robject(new_exception(interp, cls, args))
    end

    define(cls, interp, "to_s") do |args|
      obj = args.first.as_robject
      msg_sym = interp.symbols.intern("message")
      obj.ivars[msg_sym.value]? || Value.string(obj.rclass.name)
    end

    __define_getter(cls, interp, "message", Value.string(obj.rclass.name))

    cls
  end

  # Define the NameError class with additional `name` property
  private def self.define_name_error_class(interp : Interpreter, super_class : RubyClass) : RubyClass
    cls = RubyClass.new("NameError", super_class)

    define_singleton(cls, interp, "new") do |args|
      # create instance using base `new`
      inst = new_exception(interp, cls, args)

      # check for name parameter, must be second
      if name = args[2]?
        name = Value.string(name.to_s, name.label) unless name.string?
        name_sym = interp.symbols.intern("name")
        inst.ivars[name_sym.value] = name
      end
      Value.robject(inst)
    end

    __define_getter(cls, interp, "name", Value.string(obj.rclass.name))

    cls
  end
end
