require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Float` RubyClass and registers its native methods.
  #
  # Mirrors Integer's bootstrap closely — same reasoning applies:
  # arithmetic (`+`, `-`, `*`, `/`) and comparison (`<`, `<=`, `>`,
  # `>=`, `==`) are NOT registered here, since they already compile to
  # dedicated VM opcodes (Op::Add etc., see arith_add/arith_op/
  # arith_div/compare_op in vm.cr) which already handle Integer/Float
  # mixing correctly (`5 + 2.5`, `5 < 2.5`, ...) — this class exists so
  # `2.5.is_a?(Float)`, `2.5.to_s`, etc. work against a real RubyClass
  # rather than exec_builtin's receiver-agnostic fallback.
  #
  # `<=>` is NOT included: it doesn't exist as an opcode OR a method
  # for Integer either (a pre-existing gap, not introduced here) — see
  # DEVELOPMENT.md's "Forbidden and out-of-scope features" for the
  # note on why this wasn't added just for Float alone, to avoid the
  # two numeric types silently diverging in what they support.
  def self.bootstrap_float(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Float")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.as_float.to_s)
    end

    define(cls, interp, "to_i") do |args|
      # Truncates toward zero (3.7.to_i == 3, -3.7.to_i == -3) — same
      # semantics as Crystal's own Float64#to_i64, and matches real
      # Ruby's Float#to_i (NOT rounding).
      Adjutant::Value.int(args.first.as_float.to_i64)
    end

    define(cls, interp, "to_f") do |args|
      args.first
    end

    cls
  end
end
