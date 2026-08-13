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

    # Real Ruby's Float::INFINITY / Float::NAN — the values are
    # already reachable in scripts via ordinary float division
    # (`1.0 / 0.0`, `0.0 / 0.0`, see ValueOps.div, which does raw
    # IEEE-754 division with no special-case raise), but the named
    # constants themselves weren't registered anywhere. `constants` is
    # a plain writable Hash(Int32, Value) on RubyClass (see
    # find_constant), so this is a direct write, not a new mechanism.
    cls.constants[interp.symbols.intern("INFINITY").value] = Adjutant::Value.float(Float64::INFINITY)
    cls.constants[interp.symbols.intern("NAN").value] = Adjutant::Value.float(Float64::NAN)

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.as_float.to_s)
    end

    define(cls, interp, "to_i") do |args, _blk, ncc|
      # Truncates toward zero (3.7.to_i == 3, -3.7.to_i == -3) — same
      # semantics as Crystal's own Float64#to_i64, and matches real
      # Ruby's Float#to_i (NOT rounding). Infinity/NaN have no integer
      # equivalent — real Ruby raises FloatDomainError rather than
      # silently truncating to some garbage/undefined value, so this
      # checks `finite?` first and raises R016 the same way.
      val = args.first.as_float
      unless val.finite?
        ncc.raise_error("R016", {"value" => val.to_s}, "FloatDomainError")
      end
      Adjutant::Value.int(val.to_i64)
    end

    # Real Ruby's Float#ceil / #floor / #round / #truncate: with
    # ndigits > 0, rounds to that many decimal places and returns a
    # FLOAT; with ndigits <= 0 (including the default, no-arg case),
    # rounds to the nearest power of 10 and returns an INTEGER — see
    # Builtins.float_round_to_power_of_ten for the shared logic (the
    # return-type switch lives there, since only that method has
    # both the raw result and the sign of ndigits at once). Not
    # covered by the mapped-methods macro above (helpers.cr) since
    # that macro has no way to accept an argument at all — an
    # explicit method was already the only option for `to_s(base)`
    # for the same reason.
    #
    # Infinity/NaN raise the same R016/FloatDomainError as #to_i, but
    # ONLY when the result would be an Integer (ndigits <= 0) — real
    # Ruby's `Float::INFINITY.floor(2)` (ndigits > 0, stays a Float)
    # does NOT raise, it returns Infinity unchanged.
    {% for method in [:ceil, :floor, :round, :truncate] %}
    define(cls, interp, {{method.id.stringify}}) do |args, _blk, ncc|
      val = args.first.as_float
      ndigits = args[1]?.try(&.as_int) || 0_i64
      if !val.finite? && ndigits <= 0
        ncc.raise_error("R016", {"value" => val.to_s}, "FloatDomainError")
      end
      Adjutant::Builtins.float_round_to_power_of_ten(val, ndigits, {{method}}, args.first.label)
    end
    {% end %}

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
