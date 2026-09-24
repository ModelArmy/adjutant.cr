require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Array` class and its native methods. `+`, `<<`, `==`,
  # `[]` and `[]=` are opcodes (ValueOps, `values_equal?`, GetIndex and
  # SetIndex), not methods.
  # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
  def self.bootstrap_array(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Array")

    # Each element's own `inspect`, so an object's override applies.
    # A self-containing array renders as `[[...]]`. `to_s` is the
    # same.
    define(cls, interp, "inspect") do |args, _blk, ncc|
      arr = args.first.as_array
      str = ncc.guard_rendering(arr.object_id, "[...]") do
        rendered = arr.to_a.map { |elem| ncc.call_method(elem, "inspect", [] of Adjutant::Value).as_string }
        "[" + rendered.join(", ") + "]"
      end
      Adjutant::Value.string(str)
    end

    define(cls, interp, "to_s") do |args, _blk, ncc|
      ncc.call_method(args.first, "inspect", [] of Adjutant::Value)
    end

    define(cls, interp, "length") do |args|
      Adjutant::Value.int(args.first.as_array.size.to_i64)
    end

    define(cls, interp, "size") do |args|
      Adjutant::Value.int(args.first.as_array.size.to_i64)
    end

    define(cls, interp, "empty?") do |args|
      Adjutant::Value.bool(args.first.as_array.empty?)
    end

    define(cls, interp, "push") do |args|
      # Appends every argument and returns self. Each value's label
      # joins the array's, as for `<<` and `[]=`.
      arr = args.first.as_array
      args[1..].each do |v|
        arr.push(v)
        arr.label = Adjutant::RiskFlowLabel.join(arr.label, v.label)
      end
      args.first
    end

    define(cls, interp, "pop") do |args|
      arr = args.first.as_array
      arr.empty? ? Adjutant::Value.nil_value : arr.pop
    end

    define(cls, interp, "include?") do |args, _blk, ncc|
      needle = args[1]?
      found = needle ? args.first.as_array.any? { |elem| ncc.values_equal?(elem, needle) } : false
      Adjutant::Value.bool(found)
    end

    define(cls, interp, "join") do |args|
      sep = args[1]?.try(&.as_string?) || ""
      Adjutant::Value.string(args.first.as_array.map(&.to_s).join(sep))
    end

    define(cls, interp, "each") do |args, blk, ncc|
      recv = args.first
      if blk
        recv.as_array.each { |elem| ncc.invoke(blk, [elem]) }
      end
      recv
    end

    define(cls, interp, "map") do |args, blk, ncc|
      recv = args.first
      if blk
        mapped = recv.as_array.map { |elem| ncc.invoke(blk, [elem]) }
        # The result's label joins every mapped value's and the
        # receiver's.
        Adjutant::Value.new(Adjutant::LabeledArray.new(mapped, joined_label(mapped, recv.as_array.label)), nil)
      else
        Adjutant::Value.new(Adjutant::LabeledArray.new, nil)
      end
    end

    # With no argument, the first element or nil. With `n`, an Array
    # of the first `n` elements; a negative `n` raises R031
    # (`ArgumentError`), as Ruby does.
    define(cls, interp, "first") do |args, _blk, ncc|
      recv = args.first
      arr = recv.as_array
      if n_val = args[1]?
        n = n_val.as_int.to_i
        ncc.raise_error("R031", {} of String => String, "ArgumentError") if n < 0
        elements = arr.to_a.first(n)
        Adjutant::Value.new(Adjutant::LabeledArray.new(elements, joined_label(elements, recv.label)), nil)
      else
        arr[0]? || Adjutant::Value.nil_value
      end
    end

    define(cls, interp, "last") do |args, _blk, ncc|
      recv = args.first
      arr = recv.as_array
      if n_val = args[1]?
        n = n_val.as_int.to_i
        ncc.raise_error("R031", {} of String => String, "ArgumentError") if n < 0
        elements = arr.to_a.last(n)
        Adjutant::Value.new(Adjutant::LabeledArray.new(elements, joined_label(elements, recv.label)), nil)
      else
        arr.empty? ? Adjutant::Value.nil_value : arr[arr.size - 1]
      end
    end

    define(cls, interp, "select") do |args, blk, ncc|
      recv = args.first
      if blk
        kept = recv.as_array.to_a.select { |elem| ncc.invoke(blk, [elem]).truthy? }
        Adjutant::Value.new(Adjutant::LabeledArray.new(kept, joined_label(kept, recv.as_array.label)), nil)
      else
        Adjutant::Value.new(Adjutant::LabeledArray.new, nil)
      end
    end

    define(cls, interp, "reject") do |args, blk, ncc|
      recv = args.first
      if blk
        kept = recv.as_array.to_a.reject { |elem| ncc.invoke(blk, [elem]).truthy? }
        Adjutant::Value.new(Adjutant::LabeledArray.new(kept, joined_label(kept, recv.as_array.label)), nil)
      else
        Adjutant::Value.new(Adjutant::LabeledArray.new, nil)
      end
    end

    # `reduce(initial) { |acc, x| }` and `reduce { |acc, x| }`, where
    # the first element is the initial value and an empty receiver
    # gives nil. The Symbol form, `reduce(:+)`, is not implemented and
    # returns nil.
    define(cls, interp, "reduce") do |args, blk, ncc|
      items = args.first.as_array.to_a
      initial = args[1]?
      next Adjutant::Value.nil_value unless blk

      if initial
        items.reduce(initial) { |acc, elem| ncc.invoke(blk, [acc, elem]) }
      elsif items.empty?
        Adjutant::Value.nil_value
      else
        items.reduce { |acc, elem| ncc.invoke(blk, [acc, elem]) }
      end
    end

    define(cls, interp, "inject") do |args, blk, ncc|
      items = args.first.as_array.to_a
      initial = args[1]?
      next Adjutant::Value.nil_value unless blk

      if initial
        items.reduce(initial) { |acc, elem| ncc.invoke(blk, [acc, elem]) }
      elsif items.empty?
        Adjutant::Value.nil_value
      else
        items.reduce { |acc, elem| ncc.invoke(blk, [acc, elem]) }
      end
    end

    # Returns a new Array in ascending `<=>` order; does not mutate the
    # receiver. With a block, the block is the comparator: it receives
    # two elements and returns a negative, zero or positive Integer.
    # Raises R044 (`ArgumentError`) for a pair with no order, or a block
    # that returns anything but an Integer — Ruby's own behaviour, and
    # better than returning a plausible but unsorted list.
    #
    # The result's label joins every element's and the receiver's, plus,
    # with a block, every comparator result's: the order itself carries
    # whatever the block consulted.
    define(cls, interp, "sort") do |args, blk, ncc|
      recv = args.first
      items = recv.as_array.to_a
      order_label = nil.as(Adjutant::RiskFlowLabel?)
      sorted = if blk
                 items.sort do |x, y|
                   result = ncc.invoke(blk, [x, y])
                   order_label = Adjutant::RiskFlowLabel.join(order_label, result.label)
                   result.int? ? (result.as_int <=> 0) : ncc.raise_error("R044", {"left" => builtin_type_name(x), "right" => builtin_type_name(y)}, "ArgumentError")
                 end
               else
                 items.sort { |x, y| ncc.order(x, y) }
               end
      label = Adjutant::RiskFlowLabel.join(joined_label(sorted, recv.as_array.label), order_label)
      Adjutant::Value.new(Adjutant::LabeledArray.new(sorted, label), nil)
    end

    # Returns a new Array ordered by the block's result for each
    # element, compared with `<=>`, so a two-key sort is
    # `sort_by { |x| [x.a, x.b] }`. Raises R044 (`ArgumentError`) when two
    # keys have no order, and R045 (`ArgumentError`) with no block.
    #
    # The result's label joins every element's, every key's and the
    # receiver's, since the keys decide the order.
    define(cls, interp, "sort_by") do |args, blk, ncc|
      ncc.raise_error("R045", {"method" => "sort_by"}, "ArgumentError") unless blk
      recv = args.first
      keyed = recv.as_array.to_a.map { |elem| {ncc.invoke(blk, [elem]), elem} }
      keyed.sort! { |x, y| ncc.order(x[0], y[0]) }
      sorted = keyed.map(&.[1])
      label = joined_label(keyed.map(&.[0]), joined_label(sorted, recv.as_array.label))
      Adjutant::Value.new(Adjutant::LabeledArray.new(sorted, label), nil)
    end

    define(cls, interp, "reverse") do |args|
      recv = args.first
      items = recv.as_array.to_a.reverse
      Adjutant::Value.new(Adjutant::LabeledArray.new(items, joined_label(items, recv.as_array.label)), nil)
    end

    # Nil for an empty receiver, as in Ruby. Ordered as `sort` orders:
    # a pair with no order raises R044 (`ArgumentError`).
    define(cls, interp, "min") do |args, _blk, ncc|
      items = args.first.as_array.to_a
      items.empty? ? Adjutant::Value.nil_value : items.reduce { |acc, elem| ncc.order(elem, acc) < 0 ? elem : acc }
    end

    define(cls, interp, "max") do |args, _blk, ncc|
      items = args.first.as_array.to_a
      items.empty? ? Adjutant::Value.nil_value : items.reduce { |acc, elem| ncc.order(elem, acc) > 0 ? elem : acc }
    end

    # Without a block, each element's truthiness; with one, the
    # block's result.
    define(cls, interp, "any?") do |args, blk, ncc|
      items = args.first.as_array
      found = blk ? items.any? { |elem| ncc.invoke(blk, [elem]).truthy? } : items.any?(&.truthy?)
      Adjutant::Value.bool(found)
    end

    define(cls, interp, "all?") do |args, blk, ncc|
      items = args.first.as_array.to_a
      result = blk ? items.all? { |elem| ncc.invoke(blk, [elem]).truthy? } : items.all?(&.truthy?)
      Adjutant::Value.bool(result)
    end

    cls
  end
end
