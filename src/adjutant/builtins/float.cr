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
  # dedicated VM opcodes (Op::Add etc., see ValueOps.add/op/div/
  # compare in value_ops.cr) which already handle Integer/Float
  # mixing correctly (`5 + 2.5`, `5 < 2.5`, ...) — this class exists so
  # `2.5.is_a?(Float)`, `2.5.to_s`, etc. work against a real RubyClass
  # rather than exec_builtin's receiver-agnostic fallback.
  #
  # `<=>` is NOT registered here either, for the same reason as the
  # operators above: it's handled centrally, not per-class — see
  # ValueOps.spaceship (value_ops.cr) and exec_builtin's `"<=>"` case
  # (vm.cr), added 2026-08-06 alongside the `<=>`-derived comparison
  # work in SCOPE.md. Previously a real, open gap (no opcode, no
  # method, nothing) — `<=>` wasn't just unregistered here, it did not
  # work for Integer or Float at all.
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

    # Define conversion methods that return an int
    __define_mapped_methods(cls, interp, self_as: float, return_as: int, methods: [floor, ceil, round])
    __define_mapped_methods(cls, interp, self_as: float, return_as: int, methods: [truncate], crystal_methods: [trunc])

    # Define conversion methods that return a float
    __define_mapped_methods(cls, interp, self_as: float, return_as: float, methods: [abs])

    # Define conversion methods that return a string
    __define_mapped_methods(cls, interp, self_as: float, return_as: string, methods: [inspect])

    # Define conversion methods that return a bool
    __define_mapped_methods(cls, interp, self_as: float, return_as: bool, methods: [finite?, nan?])

    define(cls, interp, "infinite?") do |args|
      val = args.first.as_float
      case result = val.infinite?
      when Int then Adjutant::Value.int(result)
      else          Adjutant::Value.nil_value
      end
    end

    define(cls, interp, "to_f") do |args|
      args.first
    end

    cls
  end
end
