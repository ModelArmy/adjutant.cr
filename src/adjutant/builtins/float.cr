require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Float` class and its native methods. Arithmetic,
  # comparison and `<=>` are opcodes or VM builtins, not methods.
  def self.bootstrap_float(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Float")

    # Float::INFINITY and Float::NAN.
    cls.constants[interp.symbols.intern("INFINITY").value] = Adjutant::Value.float(Float64::INFINITY)
    cls.constants[interp.symbols.intern("NAN").value] = Adjutant::Value.float(Float64::NAN)

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.as_float.to_s)
    end

    define(cls, interp, "to_i") do |args, _blk, ncc|
      # Truncates toward zero, as in Ruby. Infinity and NaN raise R016
      # (FloatDomainError).
      val = args.first.as_float
      unless val.finite?
        ncc.raise_error("R016", {"value" => val.to_s}, "FloatDomainError")
      end
      Adjutant::Value.int(val.to_i64)
    end

    # `ceil`, `floor`, `round` and `truncate` with `ndigits`: a Float
    # for `ndigits > 0`, otherwise an Integer. Infinity and NaN raise
    # R016 only when the result would be an Integer:
    # `Float::INFINITY.floor(2)` is Infinity, as in Ruby.
    {% for method in [:ceil, :floor, :round, :truncate] %}
    define(cls, interp, {{ method.id.stringify }}) do |args, _blk, ncc|
      val = args.first.as_float
      ndigits = args[1]?.try(&.as_int) || 0_i64
      if !val.finite? && ndigits <= 0
        ncc.raise_error("R016", {"value" => val.to_s}, "FloatDomainError")
      end
      Adjutant::Builtins.float_round_to_power_of_ten(val, ndigits, {{ method }}, args.first.label)
    end
    {% end %}

    # Mapped methods returning a Float.
    __define_mapped_methods(cls, interp, self_as: float, return_as: float, methods: [abs])

    # Mapped methods returning a String.
    __define_mapped_methods(cls, interp, self_as: float, return_as: string, methods: [inspect])

    # Mapped methods returning a Bool.
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
