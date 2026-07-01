require "spec"
require "../src/adjutant"

module Adjutant
  # Helper: create an interpreter with a capturing effect handler.
  private def self.make_interp(limits : ExecutionLimits = ExecutionLimits.new) : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(effect: ef, limits: limits)
    {interp, ef}
  end

  # Helper: create an interpreter and register a module.
  private def self.make_interp_with_module(name : String, &block : Interpreter -> Nil) : {Interpreter, TestEffectHandler}
    interp, ef = make_interp
    interp.modules.register(name) { |i| block.call(i) }
    {interp, ef}
  end
end
