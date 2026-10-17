require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Range` class and its native methods. A Range is an
  # object whose `__min`, `__max` and `__exclusive` ivars are set when
  # it is built (Op::MakeRange or `Range.new`) and never change.
  # Iteration steps with each bound's own `succ`, so any bound type
  # with `succ` and `<=>` works. A Float or nil start raises R024
  # (TypeError), as in Ruby; any other start without `succ` raises
  # NoMethodError where Ruby raises TypeError, String included (see
  # SCOPE.md's entry on ranges iterated through `succ`).
  # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
  def self.bootstrap_range(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Range")

    min_sym = interp.symbols.intern("__min").value
    max_sym = interp.symbols.intern("__max").value
    excl_sym = interp.symbols.intern("__exclusive").value

    # `Range.new(begin, end, exclude_end = false)`. A nil bound builds
    # a beginless or endless range, as `..5` and `1..` do.
    define_singleton(cls, interp, "new", arity: 2..3) do |args, _blk, _ncc|
      rstart = args[1]? || Adjutant::Value.nil_value
      rend = args[2]? || Adjutant::Value.nil_value
      exclusive = args[3]?.try(&.truthy?) || false
      obj = Adjutant::RubyObject.new(cls)
      obj.ivars[min_sym] = rstart
      obj.ivars[max_sym] = rend
      obj.ivars[excl_sym] = Adjutant::Value.bool(exclusive)
      Adjutant::Value.robject(obj)
    end

    # `min` and `max` raise RangeError on a missing bound, as `first`
    # and `last` do, with Ruby's messages. Otherwise `min` is the start,
    # or nil for an empty range: a start above the end, or equal to an
    # excluded end.
    define(cls, interp, "min", arity: 0) do |args, _blk, ncc|
      obj = args.first.as_robject
      lo = obj.ivars[min_sym]
      ncc.raise_error("R029", {} of String => String, "RangeError") if lo.null?
      hi = obj.ivars[max_sym]
      next lo if hi.null?
      order = ncc.order(lo, hi)
      order > 0 || (order == 0 && obj.ivars[excl_sym].as_bool) ? Adjutant::Value.nil_value : lo
    end

    # A beginless range raises RangeError, with or without `n`, as in
    # Ruby. With `n`, an Array of the first `n` elements, which works
    # on an endless range; a negative `n` raises ArgumentError.
    define(cls, interp, "first", arity: 0..1, labels_own_result: true) do |args, _blk, ncc|
      obj = args.first.as_robject
      lo = obj.ivars[min_sym]
      ncc.raise_error("R030", {} of String => String, "RangeError") if lo.null?
      if n_val = args[1]?
        if n_val.int? && n_val.as_int < 0
          ncc.raise_error("R031", {} of String => String, "ArgumentError")
        end
        ncc.raise_error("R024", {"method" => "first", "class" => "Float"}, "TypeError") if lo.float?
        n = n_val.as_int.to_i
        hi = obj.ivars[max_sym]
        exclusive = obj.ivars[excl_sym].as_bool
        elements = [] of Adjutant::Value
        current = lo
        while elements.size < n
          in_bounds = hi.null? || (exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=))
          break unless in_bounds
          elements << range_value(current, args.first)
          current = ncc.call_method(current, "succ", [] of Adjutant::Value)
        end
        Adjutant::Value.new(Adjutant::LabeledArray.new(elements, joined_label(elements, args.first.label)), nil)
      else
        lo
      end
    end

    # The bounds as stored, nil included; never raises.
    define(cls, interp, "begin", arity: 0, labels_own_result: true) do |args|
      args.first.as_robject.ivars[min_sym]
    end

    define(cls, interp, "end", arity: 0, labels_own_result: true) do |args|
      args.first.as_robject.ivars[max_sym]
    end

    # Ruby's `Range#size`: how many Integers lie between an Integer
    # start and the end, Infinity for an endless range, nil for a start
    # that isn't a number. A nil or Float start raises R024 (TypeError),
    # as Ruby 3.3 does.
    define(cls, interp, "size", arity: 0) do |args, _blk, ncc|
      obj = args.first.as_robject
      lo = obj.ivars[min_sym]
      if lo.null? || lo.float?
        ncc.raise_error("R024", {"method" => "size", "class" => lo.null? ? "NilClass" : "Float"}, "TypeError")
      end
      next Adjutant::Value.nil_value unless lo.int?
      range_size(lo.as_int, obj.ivars[max_sym], obj.ivars[excl_sym].as_bool)
    end

    # Ruby's `Range#max`, step for step: nil for an empty range; the end
    # of an inclusive range; for an exclusive one, the Integer just
    # below its end, which needs an Integer end (R061) and an Integer
    # start (R062), both TypeError. An exclusive range whose end isn't a
    # number is walked instead, as Ruby does.
    define(cls, interp, "max", arity: 0) do |args, _blk, ncc|
      obj = args.first.as_robject
      hi = obj.ivars[max_sym]
      ncc.raise_error("R027", {} of String => String, "RangeError") if hi.null?
      exclusive = obj.ivars[excl_sym].as_bool
      if exclusive && !(hi.int? || hi.float?)
        next ncc.call_method(ncc.call_method(args.first, "to_a", [] of Adjutant::Value), "max", [] of Adjutant::Value)
      end
      lo = obj.ivars[min_sym]
      order = lo.null? ? -1 : ncc.order(lo, hi)
      next Adjutant::Value.nil_value if order > 0
      next hi unless exclusive
      ncc.raise_error("R061", {} of String => String, "TypeError") unless hi.int?
      next Adjutant::Value.nil_value if order == 0
      ncc.raise_error("R062", {} of String => String, "TypeError") unless lo.int?
      Adjutant::Value.int(hi.as_int - 1)
    end

    define(cls, interp, "last", arity: 0, labels_own_result: true) do |args, _blk, ncc|
      obj = args.first.as_robject
      hi = obj.ivars[max_sym]
      ncc.raise_error("R028", {} of String => String, "RangeError") if hi.null?
      hi
    end

    define(cls, interp, "exclude_end?", arity: 0) do |args|
      args.first.as_robject.ivars[excl_sym]
    end

    # `to_s` renders each bound with its own `to_s`, `inspect` with its
    # own `inspect`, so `("a".."c").to_s` is "a..c" and its `inspect`
    # is "\"a\"..\"c\"". A nil bound is omitted: `(..5).inspect` is
    # "..5".
    define(cls, interp, "to_s", arity: 0) do |args, _blk, ncc|
      obj = args.first.as_robject
      sep = obj.ivars[excl_sym].as_bool ? "..." : ".."
      min_v = obj.ivars[min_sym]
      max_v = obj.ivars[max_sym]
      min_str = min_v.null? ? "" : ncc.call_method(min_v, "to_s", [] of Adjutant::Value).as_string
      max_str = max_v.null? ? "" : ncc.call_method(max_v, "to_s", [] of Adjutant::Value).as_string
      Adjutant::Value.string("#{min_str}#{sep}#{max_str}")
    end

    define(cls, interp, "inspect", arity: 0) do |args, _blk, ncc|
      obj = args.first.as_robject
      sep = obj.ivars[excl_sym].as_bool ? "..." : ".."
      min_v = obj.ivars[min_sym]
      max_v = obj.ivars[max_sym]
      min_str = min_v.null? ? "" : ncc.call_method(min_v, "inspect", [] of Adjutant::Value).as_string
      max_str = max_v.null? ? "" : ncc.call_method(max_v, "inspect", [] of Adjutant::Value).as_string
      Adjutant::Value.string("#{min_str}#{sep}#{max_str}")
    end

    define(cls, interp, "include?", arity: 1) do |args, _blk, ncc|
      range_includes?(args, ncc, min_sym, max_sym, excl_sym)
    end

    # Ruby's alias of `include?`.
    define(cls, interp, "member?", arity: 1) do |args, _blk, ncc|
      range_includes?(args, ncc, min_sym, max_sym, excl_sym)
    end

    # Yields from the start up to the end (excluded if exclusive),
    # stepping with `succ`. A beginless range raises TypeError (R024),
    # as in Ruby; an endless one iterates until the block breaks.
    define(cls, interp, "each", arity: 0) do |args, blk, ncc|
      recv = args.first
      obj = recv.as_robject
      exclusive = obj.ivars[excl_sym].as_bool
      lo = obj.ivars[min_sym]
      hi = obj.ivars[max_sym]
      ncc.raise_error("R024", {"method" => "each", "class" => lo.null? ? "NilClass" : "Float"}, "TypeError") if lo.null? || lo.float?
      block = require_block!(blk, "Range#each", ncc)
      current = lo
      loop do
        in_bounds = hi.null? || (exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=))
        break unless in_bounds
        ncc.invoke(block, [range_value(current, recv)])
        current = ncc.call_method(current, "succ", [] of Adjutant::Value)
      end
      recv
    end

    # Every value `each` would yield, as an Array. Its label joins the
    # Range's and each value's. A beginless range raises TypeError
    # (R024), an endless one RangeError (R026).
    define(cls, interp, "to_a", arity: 0) do |args, _blk, ncc|
      recv = args.first
      obj = recv.as_robject
      exclusive = obj.ivars[excl_sym].as_bool
      lo = obj.ivars[min_sym]
      hi = obj.ivars[max_sym]
      ncc.raise_error("R024", {"method" => "to_a", "class" => lo.null? ? "NilClass" : "Float"}, "TypeError") if lo.null? || lo.float?
      ncc.raise_error("R026", {} of String => String, "RangeError") if hi.null?
      elements = [] of Adjutant::Value
      current = lo
      loop do
        in_bounds = exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=)
        break unless in_bounds
        elements << range_value(current, recv)
        current = ncc.call_method(current, "succ", [] of Adjutant::Value)
      end
      Adjutant::Value.new(Adjutant::LabeledArray.new(elements, joined_label(elements, recv.label)), nil)
    end

    # Like `each`, stepping by `n` with `+` rather than `succ`. A zero
    # step raises ArgumentError (R020); a beginless range raises
    # ArgumentError (R025), as Ruby does; an endless one iterates until
    # the block breaks. Without a block, returns the receiver.
    define(cls, interp, "step", arity: 0..1) do |args, blk, ncc|
      recv = args.first
      obj = recv.as_robject
      exclusive = obj.ivars[excl_sym].as_bool
      lo = obj.ivars[min_sym]
      hi = obj.ivars[max_sym]
      n = args[1]? || Adjutant::Value.int(1_i64)
      if n.int? && n.as_int == 0
        ncc.raise_error("R020", {} of String => String, "ArgumentError")
      end
      ncc.raise_error("R025", {} of String => String, "ArgumentError") if lo.null?
      block = require_block!(blk, "Range#step", ncc)
      current = lo
      loop do
        in_bounds = hi.null? || (exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=))
        break unless in_bounds
        ncc.invoke(block, [range_value(current, recv)])
        current = ncc.add(current, n)
      end
      recv
    end

    cls
  end

  # Whether `x` lies within the bounds; a nil bound is no limit on
  # its side.
  # How many Integers lie from `lo` to `hi`: none when `hi` is below
  # `lo`, Infinity when there's no end or an infinite one, nil when the
  # end isn't a number. A Float end counts the Integers at or below it.
  private def self.range_size(lo : Int64, hi : Adjutant::Value, exclusive : Bool) : Adjutant::Value
    return Adjutant::Value.float(Float64::INFINITY) if hi.null?
    top =
      if hi.int?
        exclusive ? hi.as_int - 1 : hi.as_int
      elsif hi.float?
        limit = hi.as_float
        return Adjutant::Value.float(Float64::INFINITY) if limit == Float64::INFINITY
        return Adjutant::Value.int(0_i64) if limit < lo
        exclusive && limit == limit.floor ? limit.to_i64 - 1 : limit.floor.to_i64
      else
        return Adjutant::Value.nil_value
      end
    Adjutant::Value.int(top < lo ? 0_i64 : top - lo + 1)
  end

  # `value` with `range`'s label joined in: every value a Range yields
  # or collects is computed from its bounds.
  private def self.range_value(value : Adjutant::Value, range : Adjutant::Value) : Adjutant::Value
    value.with_label(Adjutant::RiskFlowLabel.join(value.label, range.label))
  end

  private def self.range_includes?(args : Array(Adjutant::Value), ncc : Adjutant::NativeCallContext,
                                   min_sym : Int32, max_sym : Int32, excl_sym : Int32) : Adjutant::Value
    obj = args.first.as_robject
    needle = args[1]?
    return Adjutant::Value.bool(false) unless needle
    lo = obj.ivars[min_sym]
    hi = obj.ivars[max_sym]
    exclusive = obj.ivars[excl_sym].as_bool
    above_min = lo.null? || ncc.compare(needle, lo, :>=)
    below_max = hi.null? || (exclusive ? ncc.compare(needle, hi, :<) : ncc.compare(needle, hi, :<=))
    Adjutant::Value.bool(above_min && below_max)
  end
end
