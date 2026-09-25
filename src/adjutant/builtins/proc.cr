require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Proc` class and the `lambda` function. A Proc is an
  # object wrapping a ScriptProc in its `__sproc` ivar, with the
  # closure it captured in `outer_locals`; `->(){}` and `lambda { }`
  # both build one. Blocks and method bodies stay bare ScriptProcs.
  # `proc { }` is excluded (U019).
  def self.bootstrap_proc(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Proc")
    filename_sym = interp.symbols.intern("__filename").value
    line_sym = interp.symbols.intern("__line").value

    # `.call(...)`; the `.(...)` sugar isn't parsed.
    define(cls, interp, "call") do |args, _blk, ncc|
      obj = args.first.as_robject
      # `invoke_proc` takes the ScriptProc and the closure from the
      # object, so no caller can pass the wrong closure.
      ncc.invoke_proc(obj, args[1..])
    end

    # Always true: every Proc Adjutant builds is a lambda.
    define(cls, interp, "lambda?") do |_args|
      Adjutant::Value.bool(true)
    end

    # `#<Proc file:line (lambda)>`, where the lambda was written.
    # Ruby's memory address is omitted, as in `Object#inspect`.
    define(cls, interp, "to_s") do |args|
      obj = args.first.as_robject
      filename = obj.ivars[filename_sym].as_string
      line = obj.ivars[line_sym].as_int
      Adjutant::Value.string("#<Proc #{filename}:#{line} (lambda)>")
    end

    define(cls, interp, "inspect") do |args, _blk, ncc|
      ncc.call_method(args.first, "to_s", [] of Adjutant::Value)
    end

    # `lambda { ... }`: the call-site block as a Proc object. A native
    # function rather than a method of this class, since it has no
    # receiver. Private, as `Kernel#lambda` is in Ruby.
    interp.define_native("lambda", is_private: true) do |_args, blk, ncc|
      given_block = blk
      ncc.raise_error("R032", {} of String => String, "ArgumentError") unless given_block
      ncc.wrap_block_as_proc(given_block)
    end

    cls
  end
end
