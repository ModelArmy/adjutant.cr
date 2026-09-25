require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Integer` class and its native methods, all pure.
  # Arithmetic is opcodes, not methods.
  def self.bootstrap_integer(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Integer")

    # `to_s(base)`, base 2 to 36; another base raises R015
    # (ArgumentError), as in Ruby.
    define(cls, interp, "to_s") do |args, _blk, ncc|
      n = args.first.as_int
      if base_arg = args[1]?
        base = base_arg.as_int
        unless (2..36).covers?(base)
          ncc.raise_error("R015", {"base" => base.to_s}, "ArgumentError")
        end
        Adjutant::Value.string(n.to_s(base.to_i32))
      else
        Adjutant::Value.string(n.to_s)
      end
    end

    define(cls, interp, "to_i") do |args|
      args.first
    end

    define(cls, interp, "to_f") do |args|
      Adjutant::Value.float(args.first.as_int.to_f64)
    end

    # `succ` and its alias `next`, which Range iteration uses.
    define(cls, interp, "succ") do |args|
      recv = args.first
      Adjutant::Value.int(recv.as_int + 1, recv.label)
    end

    define(cls, interp, "next") do |args|
      recv = args.first
      Adjutant::Value.int(recv.as_int + 1, recv.label)
    end

    define(cls, interp, "abs") do |args|
      Adjutant::Value.int(args.first.as_int.abs)
    end

    define(cls, interp, "even?") do |args|
      Adjutant::Value.bool(args.first.as_int.even?)
    end

    define(cls, interp, "odd?") do |args|
      Adjutant::Value.bool(args.first.as_int.odd?)
    end

    define(cls, interp, "zero?") do |args|
      Adjutant::Value.bool(args.first.as_int.zero?)
    end

    # Yields 0 up to self, excluded, and returns self. Without a
    # block, returns self.
    define(cls, interp, "times") do |args, blk, ncc|
      recv = args.first
      if blk
        recv.as_int.times { |i| ncc.invoke(blk, [Adjutant::Value.int(i.to_i64)]) }
      end
      recv
    end

    # With a negative `ndigits`, rounds to a power of ten
    # (`12345.round(-2)` is 12300); otherwise returns self.
    define(cls, interp, "ceil") do |args|
      n = args.first.as_int
      ndigits = args[1]?.try(&.as_int) || 0_i64
      Adjutant::Value.int(Adjutant::Builtins.integer_round_to_power_of_ten(n, ndigits, :ceil), args.first.label)
    end

    define(cls, interp, "floor") do |args|
      n = args.first.as_int
      ndigits = args[1]?.try(&.as_int) || 0_i64
      Adjutant::Value.int(Adjutant::Builtins.integer_round_to_power_of_ten(n, ndigits, :floor), args.first.label)
    end

    define(cls, interp, "round") do |args|
      n = args.first.as_int
      ndigits = args[1]?.try(&.as_int) || 0_i64
      Adjutant::Value.int(Adjutant::Builtins.integer_round_to_power_of_ten(n, ndigits, :round), args.first.label)
    end

    define(cls, interp, "truncate") do |args|
      n = args.first.as_int
      ndigits = args[1]?.try(&.as_int) || 0_i64
      Adjutant::Value.int(Adjutant::Builtins.integer_round_to_power_of_ten(n, ndigits, :truncate), args.first.label)
    end

    cls
  end
end
