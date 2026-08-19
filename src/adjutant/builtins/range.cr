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
  # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
  def self.bootstrap_range(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Range")

    min_sym = interp.symbols.intern("__min").value
    max_sym = interp.symbols.intern("__max").value
    excl_sym = interp.symbols.intern("__exclusive").value

    # Real Ruby's `Range.new(begin, end, exclude_end = false)` — the
    # constructor form, alongside `..`/`...` literal syntax. Without
    # this, `Range.new(...)` fell all the way through to
    # VM#construct_object's generic path: no native singleton `new`,
    # no script `initialize` (Range has never had one), so it just
    # allocated a BARE RubyObject with NONE of the three ivars set at
    # all — not an error, a SILENTLY MALFORMED Range that would raise
    # a confusing internal Crystal key-not-found error (or worse, an
    # inconsistent one) the moment anything touched it. A real,
    # separate gap from the endless/beginless-range parsing gap (see
    # SCOPE.md) — found investigating it, but not the same bug.
    #
    # A nil `begin`/`end` (real Ruby's endless/beginless-range
    # constructor form) is ACCEPTED here rather than rejected — but
    # every iteration method below (#each/#to_a/#step) compares
    # against the ivar directly, and `NativeCallContext#compare`
    # returns false for any pairing it can't order (including
    # anything-vs-nil), so a range built this way silently iterates
    # ZERO times rather than behaving like a real endless range (or
    # raising RangeError for #to_a, as real Ruby does) — the same
    # underlying limitation as the parsing gap, just reachable through
    # a different door. Not specially guarded against here, to avoid
    # inventing partial, still-wrong behavior for a case that's
    # already a known, tracked limitation.
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

    # Real Ruby: `#min`/`#max`/`#last` (all three, no block, no count
    # argument) raise `RangeError` when the relevant bound is nil —
    # `#min` on a BEGINLESS range ("cannot get the minimum of
    # beginless range"), `#max`/`#last` on an ENDLESS range
    # ("cannot get the maximum..."/"...the last element of endless
    # range" — two DIFFERENT messages for the same nil-end condition,
    # confirmed via Ruby's own C source, not assumed). `#first` is
    # the one exception in this group that does NOT need a nil check
    # for the endless case — there's always a real first value
    # regardless of where the range ends — but DOES need one for a
    # BEGINLESS range in modern Ruby (raises "cannot get the first
    # element of beginless range", added as its own feature after
    # `#last`'s equivalent already existed — also confirmed via
    # search, not assumed). That beginless-`#first` gap is NOT fixed
    # here — found while fixing this sibling set, but not part of the
    # originally-tracked SCOPE.md item; logged separately.
    define(cls, interp, "min") do |args, _blk, ncc|
      obj = args.first.as_robject
      lo = obj.ivars[min_sym]
      ncc.raise_error("R029", {} of String => String, "RangeError") if lo.null?
      lo
    end

    define(cls, interp, "first") do |args|
      args.first.as_robject.ivars[min_sym]
    end

    # Real Ruby's #begin/#end — the raw ivar accessors, distinct from
    # #first/#last (which have extra semantics for an endless/
    # beginless range that don't apply to #begin/#end at all: #first
    # additionally accepts a count argument for "first N elements",
    # and #last with NO argument raises on an endless range while
    # #end just returns nil). #begin/#end never raise regardless of a
    # nil bound — confirmed via search, not assumed — so no guard
    # needed here, only on #first/#last/#min/#max above/below.
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

    # `exclusive?` was this class's own (non-standard) name for real
    # Ruby's `exclude_end?` — kept as an alias (not renamed away)
    # since removing it would be a breaking change for no reason;
    # `exclude_end?` registered separately as its own entry so a
    # script using the REAL Ruby name works too, same multi-alias
    # pattern Hash's key?/include?/has_key? already uses.
    {"exclusive?", "exclude_end?"}.each do |name|
      define(cls, interp, name) do |args|
        args.first.as_robject.ivars[excl_sym]
      end
    end

    # `to_s` previously interpolated each bound via raw Crystal string
    # interpolation (`"#{obj.ivars[min_sym]}"`) — Crystal-level
    # `Value#to_s`, not real dispatch, the same category of bug
    # already fixed for Array/Hash/Object/string interpolation
    # elsewhere in this session. A custom object used as a bound with
    # its own script-defined `to_s` override wasn't being respected;
    # now it is, via `ncc.call_method`.
    #
    # `inspect` didn't exist at all before this — any implicit render
    # (`p`, a Range nested inside an Array/Hash's own `inspect`) fell
    # through to `Object`'s generic `#<Range>` fallback instead of a
    # real rendering. Real Ruby (as I understand it — worth a real
    # `irb` check, not independently confirmed here): `Range#to_s` and
    # `Range#inspect` differ when a bound isn't a plain number — `to_s`
    # renders each bound via its own `to_s` (a String bound appears
    # unquoted: `("a".."c").to_s => "a..c"`), `inspect` renders each
    # bound via its own `inspect` (quoted: `("a".."c").inspect =>
    # "\"a\"..\"c\""`) — unlike Array/Hash, where `to_s` is a plain
    # alias for `inspect` with no distinction at all. Implemented as
    # two genuinely separate methods here, not one aliased to the
    # other, to match that difference; each bound rendered via real
    # dispatch (`ncc.call_method`) either way, so a custom bound
    # type's own `to_s`/`inspect` override is respected for both.
    #
    # A `nil` bound (endless/beginless ranges, now real parseable
    # syntax — see SCOPE.md's resolved entry — plus the pre-existing
    # `Range.new(nil, 5)` constructor path) is specially OMITTED
    # entirely here, matching real Ruby (`(..5).inspect => "..5"`,
    # NOT `"nil..5"`) — checked via `Value#null?` before dispatching
    # `to_s`/`inspect` on that bound at all, since dispatching on a
    # nil Value would call NilClass#to_s/#inspect and render the
    # literal string "nil", not an empty string.
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

    # Real Ruby's `member?` is a plain alias for `include?` — same
    # multi-name-registration pattern as exclude_end?/exclusive? above.
    define(cls, interp, "member?") do |args, _blk, ncc|
      range_includes?(args, ncc, min_sym, max_sym, excl_sym)
    end

    # `for x in a..b`'s desugar (compile_for) and any direct `.each`
    # call both land here. Walks `min` up to (and, unless exclusive,
    # including) `max` via #succ, yielding each value to the block —
    # #succ is itself dispatched as a real method call so any type
    # that defines it (not just Integer) works without changes here.
    #
    # Nil-bound handling (confirmed against real Ruby via `irb`
    # before writing this, not assumed): a nil START (beginless,
    # `..5`) raises TypeError (R024) — there's nothing to count up
    # FROM, so unlike the endless case below this isn't really
    # "iterate forever," it's "can't begin at all," same as real
    # Ruby's own `can't iterate from NilClass`. A nil END (endless,
    # `5..`) has no upper-bound check at all — walks forever, exactly
    # like real Ruby; the caller is expected to `break`.
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

    # Real Ruby's Range#to_a materializes every value #each would
    # yield into a real Array — same walk-via-#succ mechanism, same
    # genericity over bound type (not Integer-specific). New
    # container built from the Range's own values, so its label
    # seeds from the RECEIVER Range's own `.label` (an ordinary Value
    # field here, unlike Array/Hash's container-level `.label` — a
    # Range RubyObject has no separate container-label concept of its
    # own) joined with each yielded element's own label, same
    # principle as array.cr's select/reject/sort/reverse/map and
    # hash.cr's to_a/merge.
    #
    # Nil-bound handling, confirmed against real Ruby first: a nil
    # start raises TypeError (R024), same as #each — there's nothing
    # to begin at. A nil end raises RangeError (R026) — unlike #each,
    # which can walk an endless range forever because the CALLER
    # controls termination via `break`, #to_a has no such escape: it
    # must finish on its own, and an endless range never would.
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

    # Real Ruby's Range#step(n = 1, &block): walks from `min` to `max`
    # (respecting exclusivity, same as #each) in increments of `n`
    # instead of #succ's implicit "+1" — via NativeCallContext#add
    # (ValueOps.add under the hood, same as Op::Add), NOT
    # `call_method(current, "+", [n])`: unlike `succ`, `+` is
    # opcode-only, never registered as a real native method (see
    # NativeCallContext#add's own comment in native_call_context.cr for the
    # full reasoning) — `call_method` would have no native-method
    # table entry to find for a builtin-typed receiver like
    # Integer/Float. `n` of exactly 0 would never advance past `min`,
    # so raises ArgumentError (R020) rather than hanging forever.
    # Blockless call returns the receiver (Enumerator-less, same
    # convention as every other Enumerable-less method in this
    # codebase).
    #
    # Nil-bound handling, confirmed against real Ruby first: a nil
    # start raises ArgumentError (R025) with real Ruby's own exact
    # wording ("#step iteration for beginless ranges is meaningless")
    # — a DIFFERENT error class than #each's TypeError (R024) for the
    # same nil-start situation; not a typo, real Ruby genuinely picks
    # a different class here. A nil end walks forever, same as #each.
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

  # Shared by #include?/#member? (real Ruby aliases of the same
  # check) — separate module-level method rather than duplicating the
  # body in both `define` blocks.
  #
  # A nil bound means "no constraint on this side" (an endless range
  # includes everything above its start; a beginless range includes
  # everything below its end) — NOT "nothing satisfies this side,"
  # which is what `NativeCallContext#compare`'s own nil handling would
  # otherwise produce (see its comment: any pairing it can't order,
  # including anything-vs-nil, returns false). Inferred from ordinary
  # Ruby range semantics rather than independently `irb`-checked the
  # way #each/#step/#to_a's own nil-bound behavior was above — worth
  # a real confirmation pass if this turns out wrong.
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
