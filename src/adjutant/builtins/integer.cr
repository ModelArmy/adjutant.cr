require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Integer` RubyClass and registers its native methods.
  #
  # All methods here are pure (RiskProfile.none) — Integer has no
  # side-effecting operations. Arithmetic (`+`, `-`, `*`, `/`, `%`) is
  # NOT registered here: it compiles to dedicated VM opcodes
  # (Op::Add etc.), a separate fast path from method dispatch, and
  # isn't reached through find_native_method. This class exists so
  # `5.is_a?(Integer)`, `5.to_s`, etc. work against a real RubyClass
  # rather than exec_builtin's receiver-agnostic fallback.
  def self.bootstrap_integer(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Integer")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.as_int.to_s)
    end

    define(cls, interp, "to_i") do |args|
      args.first
    end

    define(cls, interp, "to_f") do |args|
      Adjutant::Value.float(args.first.as_int.to_f64)
    end

    cls
  end
end
