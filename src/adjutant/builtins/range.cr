require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Range` RubyClass and registers its native methods.
  #
  # Unlike Array/Hash (LabeledArray/LabeledHash-wrapped Crystal
  # containers) or Integer/Float/String (VM-opcode-backed, no storage
  # of their own), a Range is a real RubyObject with three ivars —
  # @min, @max, @exclusive — set once at construction (Op::MakeRange,
  # see vm.cr) and never mutated after. This replaces the earlier
  # `[start, end, exclusive_flag]` LabeledArray stand-in noted in
  # research/IFC_DESIGN.md and the 2026-07-14 handoff: that
  # representation had no RubyClass behind it at all, so
  # `(1..3).is_a?(Range)` and `(1..3).class` didn't resolve correctly,
  # and there was nowhere to hang a real #each.
  #
  # #each is implemented via #succ (see builtins/integer.cr for
  # Integer#succ), matching real Ruby's own Range#each rather than
  # hardcoding "is this an Integer range" — any bound type with a
  # #succ and an orderable comparison (see NativeCallContext#compare)
  # works the same way. Non-Integer bounds (e.g. String, once
  # String#succ exists) will work without any change here. A bound
  # type with no #succ raises NoMethodError on #each, same as real
  # Ruby — not specially handled, since that's accurate behavior, not
  # a gap.
  def self.bootstrap_range(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Range")

    min_sym = interp.symbols.intern("__min").value
    max_sym = interp.symbols.intern("__max").value
    excl_sym = interp.symbols.intern("__exclusive").value

    define(cls, interp, "min") do |args|
      args.first.as_robject.ivars[min_sym]
    end

    define(cls, interp, "first") do |args|
      args.first.as_robject.ivars[min_sym]
    end

    define(cls, interp, "max") do |args|
      args.first.as_robject.ivars[max_sym]
    end

    define(cls, interp, "last") do |args|
      args.first.as_robject.ivars[max_sym]
    end

    define(cls, interp, "exclusive?") do |args|
      args.first.as_robject.ivars[excl_sym]
    end

    # Note: this only fires for an explicit script-level `.to_s` call
    # (goes through real dispatch_call). Value#to_s's Crystal-level
    # fallback for a RubyObject (used by string interpolation, `puts`,
    # etc. when no explicit `.to_s` is called) does NOT consult this —
    # it prints "#<Range>" via RubyObject#to_s's generic default. Same
    # pre-existing, broader gap the 2026-07-14 handoff already flagged
    # for Array/Hash (Value#to_s has no Array/Hash case either); not
    # fixed here since it's a Value#to_s-wide limitation, not specific
    # to Range, and touching it risks unrelated behavior changes.
    define(cls, interp, "to_s") do |args|
      obj = args.first.as_robject
      sep = obj.ivars[excl_sym].as_bool ? "..." : ".."
      Adjutant::Value.string("#{obj.ivars[min_sym]}#{sep}#{obj.ivars[max_sym]}")
    end

    define(cls, interp, "include?") do |args, _blk, ncc|
      obj = args.first.as_robject
      needle = args[1]?
      if needle
        lo = obj.ivars[min_sym]
        hi = obj.ivars[max_sym]
        exclusive = obj.ivars[excl_sym].as_bool
        above_min = ncc.compare(needle, lo, :>=)
        below_max = exclusive ? ncc.compare(needle, hi, :<) : ncc.compare(needle, hi, :<=)
        Adjutant::Value.bool(above_min && below_max)
      else
        Adjutant::Value.bool(false)
      end
    end

    # `for x in a..b`'s desugar (compile_for) and any direct `.each`
    # call both land here. Walks `min` up to (and, unless exclusive,
    # including) `max` via #succ, yielding each value to the block —
    # #succ is itself dispatched as a real method call so any type
    # that defines it (not just Integer) works without changes here.
    define(cls, interp, "each") do |args, blk, ncc|
      recv = args.first
      obj = recv.as_robject
      exclusive = obj.ivars[excl_sym].as_bool
      hi = obj.ivars[max_sym]
      if blk
        current = obj.ivars[min_sym]
        loop do
          in_bounds = exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=)
          break unless in_bounds
          ncc.invoke(blk, [current])
          current = ncc.call_method(current, "succ", [] of Adjutant::Value)
        end
      end
      recv
    end

    cls
  end
end
