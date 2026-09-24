require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Range` class and its native methods. A Range is an
  # object whose `__min`, `__max` and `__exclusive` ivars are set when
  # it is built (Op::MakeRange or `Range.new`) and never change.
  # Iteration steps with each bound's own `succ`, so any bound type
  # with `succ` and `<=>` works; one without raises NoMethodError, as
  # in Ruby.
  # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
  def self.bootstrap_range(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Range")

    min_sym = interp.symbols.intern("__min").value
    max_sym = interp.symbols.intern("__max").value
    excl_sym = interp.symbols.intern("__exclusive").value

    # `Range.new(begin, end, exclude_end = false)`. A nil bound builds
    # a beginless or endless range, as `..5` and `1..` do.
    define_singleton(cls, interp, "new") do |args, _blk, _ncc|
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
    # and `last` do, with Ruby's messages.
    define(cls, interp, "min") do |args, _blk, ncc|
      obj = args.first.as_robject
      lo = obj.ivars[min_sym]
      ncc.raise_error("R029", {} of String => String, "RangeError") if lo.null?
      lo
    end

    # A beginless range raises RangeError, with or without `n`, as in
    # Ruby. With `n`, an Array of the first `n` elements, which works
    # on an endless range; a negative `n` raises ArgumentError.
    define(cls, interp, "first") do |args, _blk, ncc|
      obj = args.first.as_robject
      lo = obj.ivars[min_sym]
      ncc.raise_error("R030", {} of String => String, "RangeError") if lo.null?
      if n_val = args[1]?
        if n_val.int? && n_val.as_int < 0
          ncc.raise_error("R031", {} of String => String, "ArgumentError")
        end
        n = n_val.as_int.to_i
        hi = obj.ivars[max_sym]
        exclusive = obj.ivars[excl_sym].as_bool
        elements = [] of Adjutant::Value
        current = lo
        while elements.size < n
          in_bounds = hi.null? || (exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=))
          break unless in_bounds
          elements << current
          current = ncc.call_method(current, "succ", [] of Adjutant::Value)
        end
        Adjutant::Value.new(Adjutant::LabeledArray.new(elements, joined_label(elements, args.first.label)), nil)
      else
        lo
      end
    end

    # The bounds as stored, nil included; never raises.
    define(cls, interp, "begin") do |args|
      args.first.as_robject.ivars[min_sym]
    end

    define(cls, interp, "end") do |args|
      args.first.as_robject.ivars[max_sym]
    end

    define(cls, interp, "max") do |args, _blk, ncc|
      obj = args.first.as_robject
      hi = obj.ivars[max_sym]
      ncc.raise_error("R027", {} of String => String, "RangeError") if hi.null?
      hi
    end

    define(cls, interp, "last") do |args, _blk, ncc|
      obj = args.first.as_robject
      hi = obj.ivars[max_sym]
      ncc.raise_error("R028", {} of String => String, "RangeError") if hi.null?
      hi
    end

    # `exclude_end?` is Ruby's name; `exclusive?` is not Ruby.
    {"exclusive?", "exclude_end?"}.each do |name|
      define(cls, interp, name) do |args|
        args.first.as_robject.ivars[excl_sym]
      end
    end

    # `to_s` renders each bound with its own `to_s`, `inspect` with its
    # own `inspect`, so `("a".."c").to_s` is "a..c" and its `inspect`
    # is "\"a\"..\"c\"". A nil bound is omitted: `(..5).inspect` is
    # "..5".
    define(cls, interp, "to_s") do |args, _blk, ncc|
      obj = args.first.as_robject
      sep = obj.ivars[excl_sym].as_bool ? "..." : ".."
      min_v = obj.ivars[min_sym]
      max_v = obj.ivars[max_sym]
      min_str = min_v.null? ? "" : ncc.call_method(min_v, "to_s", [] of Adjutant::Value).as_string
      max_str = max_v.null? ? "" : ncc.call_method(max_v, "to_s", [] of Adjutant::Value).as_string
      Adjutant::Value.string("#{min_str}#{sep}#{max_str}")
    end

    define(cls, interp, "inspect") do |args, _blk, ncc|
      obj = args.first.as_robject
      sep = obj.ivars[excl_sym].as_bool ? "..." : ".."
      min_v = obj.ivars[min_sym]
      max_v = obj.ivars[max_sym]
      min_str = min_v.null? ? "" : ncc.call_method(min_v, "inspect", [] of Adjutant::Value).as_string
      max_str = max_v.null? ? "" : ncc.call_method(max_v, "inspect", [] of Adjutant::Value).as_string
      Adjutant::Value.string("#{min_str}#{sep}#{max_str}")
    end

    define(cls, interp, "include?") do |args, _blk, ncc|
      range_includes?(args, ncc, min_sym, max_sym, excl_sym)
    end

    # Ruby's alias of `include?`.
    define(cls, interp, "member?") do |args, _blk, ncc|
      range_includes?(args, ncc, min_sym, max_sym, excl_sym)
    end

    # Yields from the start up to the end (excluded if exclusive),
    # stepping with `succ`. A beginless range raises TypeError (R024),
    # as in Ruby; an endless one iterates until the block breaks.
    define(cls, interp, "each") do |args, blk, ncc|
      recv = args.first
      obj = recv.as_robject
      exclusive = obj.ivars[excl_sym].as_bool
      lo = obj.ivars[min_sym]
      hi = obj.ivars[max_sym]
      ncc.raise_error("R024", {"method" => "each"}, "TypeError") if lo.null?
      if blk
        current = lo
        loop do
          in_bounds = hi.null? || (exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=))
          break unless in_bounds
          ncc.invoke(blk, [current])
          current = ncc.call_method(current, "succ", [] of Adjutant::Value)
        end
      end
      recv
    end

    # Every value `each` would yield, as an Array. Its label joins the
    # Range's and each value's. A beginless range raises TypeError
    # (R024), an endless one RangeError (R026).
    define(cls, interp, "to_a") do |args, _blk, ncc|
      recv = args.first
      obj = recv.as_robject
      exclusive = obj.ivars[excl_sym].as_bool
      lo = obj.ivars[min_sym]
      hi = obj.ivars[max_sym]
      ncc.raise_error("R024", {"method" => "to_a"}, "TypeError") if lo.null?
      ncc.raise_error("R026", {} of String => String, "RangeError") if hi.null?
      elements = [] of Adjutant::Value
      current = lo
      loop do
        in_bounds = exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=)
        break unless in_bounds
        elements << current
        current = ncc.call_method(current, "succ", [] of Adjutant::Value)
      end
      Adjutant::Value.new(Adjutant::LabeledArray.new(elements, joined_label(elements, recv.label)), nil)
    end

    # Like `each`, stepping by `n` with `+` rather than `succ`. A zero
    # step raises ArgumentError (R020); a beginless range raises
    # ArgumentError (R025), as Ruby does; an endless one iterates until
    # the block breaks. Without a block, returns the receiver.
    define(cls, interp, "step") do |args, blk, ncc|
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
      if blk
        current = lo
        loop do
          in_bounds = hi.null? || (exclusive ? ncc.compare(current, hi, :<) : ncc.compare(current, hi, :<=))
          break unless in_bounds
          ncc.invoke(blk, [current])
          current = ncc.add(current, n)
        end
      end
      recv
    end

    cls
  end

  # Whether `x` lies within the bounds; a nil bound is no limit on
  # its side.
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
