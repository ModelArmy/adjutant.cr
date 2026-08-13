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

    # Real Ruby's Integer#succ / #next (aliases of each other) — the
    # mechanism Range#each iterates with (see builtins/range.cr),
    # matching Ruby's own Range implementation rather than requiring
    # a special-cased "is this an Integer range" branch there.
    define(cls, interp, "succ") do |args|
      Adjutant::Value.int(args.first.as_int + 1)
    end

    define(cls, interp, "next") do |args|
      Adjutant::Value.int(args.first.as_int + 1)
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

    # Real Ruby's Integer#ceil / #floor / #round / #truncate (no-arg
    # form) are no-ops that return self — an Integer is already
    # integral. Included alongside times/abs/etc. since Crystal's
    # Int64 already implements the same no-arg behavior (`#trunc` is
    # Crystal's name for Ruby's `#truncate`), so these are free
    # one-liners, not new work. The ndigits-argument form (e.g.
    # `1234.round(-2)`) is NOT covered here — left for a future pass,
    # likely alongside Float's own round/ceil/floor work where the
    # argument handling actually matters.
    define(cls, interp, "ceil") do |args|
      args.first
    end

    define(cls, interp, "floor") do |args|
      args.first
    end

    define(cls, interp, "round") do |args|
      args.first
    end

    define(cls, interp, "truncate") do |args|
      args.first
    end

    cls
  end
end
