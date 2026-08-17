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

    # `args.first.as_rclass` — the ACTUAL receiver this singleton
    # method was called on (`TypeError`, `ArgumentError`, whichever),
    # not the closure-captured `cls` from THIS method's own
    # definition-time scope (always the base `Exception` class,
    # regardless of which subclass `.new` was actually called on).
    # Found 2026-08-17: `TypeError.new("msg")` built an `Exception`-
    # classed object, not a `TypeError`-classed one — silently, no
    # error, since every EXISTING test constructed typed errors via
    # `raise TypeError, "msg"` instead (a genuinely separate,
    # already-correct path — `make_error_object`, vm.cr), never
    # exercising `.new` on a subclass directly. See exceptions_spec.cr
    # for the regression coverage this fix needed.
    define_singleton(cls, interp, "new") do |args|
      Value.robject(new_exception(interp, args.first.as_rclass, args))
    end

    define(cls, interp, "to_s") do |args|
      obj = args.first.as_robject
      msg_sym = interp.symbols.intern("message")
      obj.ivars[msg_sym.value]? || Value.string(obj.rclass.name)
    end

    # Real Ruby: `Exception#inspect` wraps `#to_s`'s own result —
    # `#<ClassName: message>` (or `#<ClassName: ClassName>` when no
    # message was given, since `to_s` above already falls back to the
    # class name in that case) — as I recall it, not independently
    # confirmed here; worth a real `irb` check. Deliberately calls
    # real dispatch on `to_s` (`ncc.call_method`), not the raw
    # `message` ivar directly, so a script's own subclass overriding
    # `to_s` (`class MyError < StandardError; def to_s; "custom";
    # end; end`) has that override reflected in `inspect` too,
    # matching real Ruby's own default `Exception#inspect`
    # implementation, which does the same internal call. Registered
    # here on the base `Exception` class, same as `to_s` above — every
    # subclass inherits it, and `obj.rclass.name` (not `cls.name`,
    # the DEFINING class) correctly reports the actual instance's own
    # class.
    define(cls, interp, "inspect") do |args, _blk, ncc|
      obj = args.first.as_robject
      message = ncc.call_method(args.first, "to_s", [] of Value).as_string
      Value.string("#<#{obj.rclass.name}: #{message}>")
    end

    __define_getter(cls, interp, "message", Value.string(obj.rclass.name))

    cls
  end

  # Define the NameError class with additional `name` property
  private def self.define_name_error_class(interp : Interpreter, super_class : RubyClass) : RubyClass
    cls = RubyClass.new("NameError", super_class)

    # Same closure-capture bug, same fix, as Exception's own `new`
    # just above — `cls` here would always be `NameError` (this
    # method's own definition-time scope), even when called as
    # `NoMethodError.new(...)` (a subclass inheriting this same
    # singleton method, with no `new` of its own).
    define_singleton(cls, interp, "new") do |args|
      # create instance using base `new`
      inst = new_exception(interp, args.first.as_rclass, args)

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
