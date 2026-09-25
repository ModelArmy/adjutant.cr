require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Defines Exception and its subclasses, yielding each to register.
  def self.bootstrap_exception_and_subclasses(interp : Interpreter, & : -> RubyClass) : Nil
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

    # Risk-flow errors.
    yield risk_flow_policy_error = RubyClass.new("RiskFlowPolicyError", standard_error)
    yield RubyClass.new("RiskFlowRejectedError", risk_flow_policy_error)
  end

  # A new error object of `cls`, with the message if given.
  private def self.new_exception(interp : Interpreter, cls : RubyClass, args : Array(Value)) : RubyObject
    inst = RubyObject.new(cls)
    # `args[0]` is the class.
    if msg = args[1]?
      msg = Value.string(msg.to_s, msg.label) unless msg.string?
      msg_sym = interp.symbols.intern("message")
      inst.ivars[msg_sym.value] = msg
    end
    inst
  end

  # Defines Exception, with its `message`.
  private def self.define_exception_class(interp : Interpreter) : RubyClass
    cls = RubyClass.new("Exception")

    # Allocates the receiver's class, so `TypeError.new("msg")` is a
    # TypeError.
    define_singleton(cls, interp, "new") do |args|
      Value.robject(new_exception(interp, args.first.as_rclass, args))
    end

    define(cls, interp, "to_s") do |args|
      obj = args.first.as_robject
      msg_sym = interp.symbols.intern("message")
      obj.ivars[msg_sym.value]? || Value.string(obj.rclass.name)
    end

    # `#<ClassName: message>`, using the object's own `to_s`, so an
    # override applies; `#<ClassName: ClassName>` with no message.
    define(cls, interp, "inspect") do |args, _blk, ncc|
      obj = args.first.as_robject
      message = ncc.call_method(args.first, "to_s", [] of Value).as_string
      Value.string("#<#{obj.rclass.name}: #{message}>")
    end

    __define_getter(cls, interp, "message", Value.string(obj.rclass.name))

    cls
  end

  # Defines NameError, with its `name`.
  private def self.define_name_error_class(interp : Interpreter, super_class : RubyClass) : RubyClass
    cls = RubyClass.new("NameError", super_class)

    # Allocates the receiver's class, as Exception's `new` does, so
    # `NoMethodError.new` is a NoMethodError.
    define_singleton(cls, interp, "new") do |args|
      inst = new_exception(interp, args.first.as_rclass, args)

      # The name is the second argument, after the message.
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
