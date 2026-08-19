require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Array` RubyClass and registers its native methods.
  #
  # `+` and `<<` are NOT registered here — `+` (concatenation, returns
  # a new array) is now a real ValueOps.add case, and `<<` (in-place
  # append, returns self) is a real ValueOps.shl case — see
  # value_ops.cr, both extended alongside this class since real Ruby
  # overloads those operators across Integer/String/Array and they're
  # unreachable via find_native_method regardless (same reasoning as
  # Integer/Float/String's own arithmetic). `[]`/`[]=` are also
  # already real opcodes
  # (Op::GetIndex/Op::SetIndex, see exec_get_index/exec_set_index) —
  # not registered here either. `==` (deep, element-wise) is a real
  # values_equal? case, also extended alongside this class.
  #
  # `length`/`size` follow String's precedent: previously served by
  # exec_builtin's generic fallback, now authoritative here via
  # find_native_method (checked first in dispatch).
  #
  # `each`/`map` are the first native methods that actually invoke a
  # script-provided block, via NativeCallContext#invoke — confirmed
  # working end-to-end by existing block-from-native machinery (see
  # DEVELOPMENT.md's Object model section) before this file was
  # written, not assumed.
  # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
  def self.bootstrap_array(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Array")

    # Real Ruby (as I understand it — worth a real `irb` check, not
    # independently confirmed here): `Array#to_s` is a plain alias for
    # `Array#inspect` — identical output, no separate algorithm.
    # `to_s` here calls real dispatch on `inspect` (`ncc.call_method`)
    # rather than duplicating the same rendering logic in two places —
    # pointless in practice today, since `U003` forbids reopening
    # `Array` (or any builtin) to override just one of the two, but
    # still the correct single-source-of-truth shape regardless.
    #
    # `inspect` itself: each element rendered via ITS OWN real
    # `inspect` (`ncc.call_method`, not a hand-rolled per-type case) —
    # a nested custom object's own `#inspect` override is respected
    # for free, the same way `Object#inspect`'s ivar rendering already
    # works (builtins/object.cr). Cycle-guarded (see
    # NativeCallContext#guard_rendering's own comment): a genuinely self-
    # referential array now renders as `[[...]]`, matching real Ruby,
    # rather than recursing until the native stack overflows — this
    # guard did not exist before this method could actually recurse,
    # since the old `to_s` (a Crystal-level `args.first.to_s` call)
    # never walked elements at all.
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
      # Real Ruby's Array#push accepts multiple arguments and appends
      # all of them, returning self — `args[1..]` is every argument
      # after the receiver, not just one.
      #
      # Joins each pushed value's label into the CONTAINER's own
      # label (arr.label=), matching `<<`'s existing behavior
      # (ValueOps.shl) and Op::SetIndex's own convention
      # (exec_set_index, vm.cr) — without this, `arr.push(tainted)`
      # would silently leave the container's own label untouched even
      # though `arr << tainted` already taints it, a real,
      # pre-existing inconsistency between the two ways to append.
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
        # New container from a block whose results have their own
        # (possibly labeled) provenance — join across the mapped
        # results, same principle as Op::MakeArray's construction-time
        # join, since this is also constructing a brand new container.
        # Seeded with the RECEIVER's own container-level label too
        # (see joined_label's own comment) — a container tainted at
        # the container level (not reflected in any element) should
        # still taint whatever's derived from it, even once every
        # element has been transformed into a brand new computed
        # value.
        Adjutant::Value.new(Adjutant::LabeledArray.new(mapped, joined_label(mapped, recv.as_array.label)), nil)
      else
        Adjutant::Value.new(Adjutant::LabeledArray.new, nil)
      end
    end

    # `#first(n)`/`#last(n)` (the count-argument form): real Ruby
    # returns an Array of the first/last `n` elements, not a single
    # value — same class of gap `Range#first(n)` had before its own
    # fix (see SCOPE.md/git history, 2026-08-19). Simpler here than
    # Range's version was: an Array already has every element in
    # hand, so this is a plain slice, no `#succ`-walking needed.
    # Negative `n` raises ArgumentError, reusing R031 as-is — same
    # message real Ruby gives for `Array#first(-1)`, which is in fact
    # what R031's wording was written against in the first place (see
    # its own comment in error_catalog.cr).
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

    # Real Ruby's Array#reduce/#inject supports both `reduce(initial)
    # { |acc, x| ... }` and `reduce { |acc, x| ... }` (initial
    # defaults to the first element, and an empty receiver with no
    # initial returns nil). NOT supported here: the symbol-operator
    # form (`reduce(:+)`, `reduce(0, :+)`) — out of scope, since it
    # needs call_method-by-symbol-name plumbing this method has no
    # reason to grow just for a shorthand real Ruby itself defines in
    # terms of the block form anyway. A blockless call with no symbol
    # returns nil rather than an Enumerator (unsupported, same as
    # every other Enumerable-less method here).
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

    # Ordering comes from NativeCallContext#compare (real `<=>`-backed
    # comparison, working for base types AND a RubyObject with its own
    # `<=>` — see that method's own comment), not a hand-rolled
    # numeric/string case split — so `sort` works for any element type
    # `<`/`>`  already works for, including user-defined objects with
    # their own `<=>`, matching real Ruby's `Comparable`-derived sort
    # rather than a narrower built-in-types-only version. Returns a
    # NEW array; does not mutate the receiver.
    define(cls, interp, "sort") do |args, _blk, ncc|
      recv = args.first
      items = recv.as_array.to_a
      sorted = items.sort { |elem_a, elem_b| ncc.compare(elem_a, elem_b, :<) ? -1 : (ncc.compare(elem_a, elem_b, :>) ? 1 : 0) }
      Adjutant::Value.new(Adjutant::LabeledArray.new(sorted, joined_label(sorted, recv.as_array.label)), nil)
    end

    define(cls, interp, "reverse") do |args|
      recv = args.first
      items = recv.as_array.to_a.reverse
      Adjutant::Value.new(Adjutant::LabeledArray.new(items, joined_label(items, recv.as_array.label)), nil)
    end

    # Real Ruby's Array#min/#max on an empty receiver return nil,
    # matched here rather than raising — same reduce-based ordering as
    # #sort, just without materializing a whole sorted copy for a
    # single extremum.
    define(cls, interp, "min") do |args, _blk, ncc|
      items = args.first.as_array.to_a
      items.empty? ? Adjutant::Value.nil_value : items.reduce { |acc, elem| ncc.compare(elem, acc, :<) ? elem : acc }
    end

    define(cls, interp, "max") do |args, _blk, ncc|
      items = args.first.as_array.to_a
      items.empty? ? Adjutant::Value.nil_value : items.reduce { |acc, elem| ncc.compare(elem, acc, :>) ? elem : acc }
    end

    # Real Ruby's Array#any?/#all? with no block test each element's
    # own truthiness; with a block, test the block's return value per
    # element instead — both forms supported here, matching
    # Array#include?'s existing style of branching on whether an
    # optional argument (there, the needle; here, the block) was
    # given.
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
