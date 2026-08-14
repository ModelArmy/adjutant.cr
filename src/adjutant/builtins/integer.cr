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

    # Real Ruby's Integer#to_s(base) accepts an optional base (2..36);
    # with no argument it's the plain base-10 rendering already
    # covered below. Crystal's own Int64#to_s(base) already does the
    # actual radix conversion — this is mostly argument validation:
    # real Ruby raises ArgumentError for a base outside 2..36, so an
    # out-of-range base is rejected the same way here (R015), rather
    # than either silently clamping it or letting Crystal's own
    # ArgumentError escape as an opaque internal N001 (see
    # NativeCallContext#raise_error's own comment for why that path
    # exists).
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

    # Real Ruby's Integer#succ / #next (aliases of each other) — the
    # mechanism Range#each iterates with (see builtins/range.cr),
    # matching Ruby's own Range implementation rather than requiring
    # a special-cased "is this an Integer range" branch there.
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

    # Real Ruby's Integer#times yields 0...self and returns self,
    # same shape as Array#each — a receiver with no block is valid
    # Ruby too (would normally return an Enumerator; unsupported here
    # per the Enumerator-less scope, so a blockless call is just a
    # no-op that returns self).
    define(cls, interp, "times") do |args, blk, ncc|
      recv = args.first
      if blk
        recv.as_int.times { |i| ncc.invoke(blk, [Adjutant::Value.int(i.to_i64)]) }
      end
      recv
    end

    # Real Ruby's Integer#ceil / #floor / #round / #truncate: with no
    # argument (or a non-negative ndigits) these are no-ops that
    # return self — an Integer is already integral. With a NEGATIVE
    # ndigits, they round to the nearest power of 10 instead (e.g.
    # `12345.round(-2) == 12300`) — see
    # Builtins.integer_round_to_power_of_ten for the shared logic.
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
