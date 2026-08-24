require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

# A single pending lazy operation in a stream's chain — the script
# BLOCK captured at `.map`/`.select`/`.reject`/`.take` call time, NOT
# invoked there. See StreamObject's own comment for why: the
# NativeCallContext an operator call receives is only valid for that
# one call, but the block must run LATER, when a terminal (`.each`,
# `.to_a`, ...) walks the chain with its OWN fresh, valid ncc.
module Adjutant
  struct StreamOp
    enum Kind
      Map
      Select
      Reject
      Take
    end

    getter kind : Kind
    getter block : ScriptProc?
    getter limit : Int32?

    def initialize(@kind : Kind, @block : ScriptProc? = nil, @limit : Int32? = nil)
    end
  end

  # A Legate stream's real state: a Crystal `Iterator(Value)` (the
  # pull-based source — single-pass by nature, so re-pulling an
  # exhausted one costs nothing extra to enforce, LEGATE.md §6.1's
  # "single pass" requirement falls out of using a real Crystal
  # Iterator rather than something needing its own bookkeeping) plus
  # the ordered list of pending `StreamOp`s not yet applied.
  #
  # `map`/`select`/`reject`/`take` each return a NEW StreamObject
  # wrapping the SAME `source` reference with one more op appended —
  # meaning two streams derived from a common ancestor (`a =
  # s.select{}; b = s.map{}`) share pull POSITION, so consuming one
  # advances the other too. This matches real Ruby's own aliasing
  # behavior on a shared IO-backed `Enumerator::Lazy`, not an
  # Adjutant-specific limitation — not prevented, just noted (see the
  # design conversation this file came out of).
  #
  # A real Crystal-only field (`source`, an `Iterator(Value)`) means
  # this is exposed to the SAME `dup`/`clone`-loses-typed-state bug
  # `TimeObject`/`RegexpObject`/`MatchDataObject` already are
  # (SCOPE.md's Must Fix) — unavoidable here, since a lazy pull source
  # fundamentally can't be represented as plain ivars the way
  # `Legate::Path` and friends could.
  class StreamObject < RubyObject
    property source : Iterator(Value)
    property ops : Array(StreamOp)

    def initialize(rclass : RubyClass, @source : Iterator(Value), @ops : Array(StreamOp) = [] of StreamOp)
      super(rclass)
    end
  end

  module Legate
    # `Legate::Stream` — LEGATE.md §6. A real Adjutant MODULE, formally
    # `include`d by every concrete stream type (`Legate::Lines`/
    # `Bytes`/`Records`, once built) — genuinely reusing Adjutant's own
    # `included_modules` method resolution (confirmed: `find_native_method`
    # walks it, same as `find_method` does for script methods), not a
    # simulation of Ruby's `Enumerable`-style mixin. Deliberately NOT
    # built on top of a general eager `Enumerable` module (Adjutant has
    # none yet, and building one was considered and deferred — see the
    # design conversation this file came out of): real `Enumerable`
    # is eager (`#map` runs `#each` to completion immediately, returns
    # an `Array`), but §6.2's own "streaming-safe operators" are lazy
    # (`#map` returns a new STREAM, nothing runs yet) — the actual
    # shape needed is closer to `Enumerator::Lazy`, which needed its
    # own purpose-built machinery here regardless.
    #
    # PHASE 1 (this file): the core lazy-chain machinery plus the most
    # load-bearing methods — `map`, `select`, `reject`, `each`, `to_a`,
    # `first(n)`, `take(n)`, `sum`, `count`. The remaining ~27 methods
    # from §6.2/§6.3/§6.4 (`flat_map`, `filter_map`, `drop`,
    # `each_slice`, `each_cons`, `with_index`, `zip`, `chunk_while`,
    # `uniq_by`, `min`/`max`/`min_by`/`max_by`/`reduce`/`find`/`any?`/
    # `all?`/`none?`/`include?`/`top_by`/`tally`, `sort`/`sort_by`/
    # `group_by`/`uniq`) are a deliberate, scoped follow-up, not an
    # oversight.
    #
    # No real data source exists yet (`Legate.lines`/etc. — the
    # broker's job, not built until a later step) — this file operates
    # on WHATEVER `Iterator(Value)` a `StreamObject` was constructed
    # with; for now, that's an in-memory test source.
    module Stream
      # NOTE ON VERIFICATION: `Iterator::Stop` (Crystal's own
      # end-of-iteration sentinel, `#next : T | Iterator::Stop`) is
      # written from recollection of Crystal's stdlib API, not
      # independently confirmed against a live toolchain here — same
      # caveat `builtins/regexp.cr`/`builtins/time.cr` already flag
      # for their own Crystal stdlib assumptions. If `ops test`/`ops
      # build` reports an unknown type here, this is the first place
      # to look.
      #
      # Fixed for now — LEGATE.md §6.4 requires materialising
      # terminals (`to_a` here; `sort`/`sort_by`/`group_by`/`uniq`
      # once built) to be bounded by "the policy's memory cap," which
      # doesn't exist as a real, configurable concept yet (that's
      # grants/broker territory — a later step). A fixed constant is
      # the honest placeholder: enforces the REAL requirement (raise
      # `Legate::TooLarge` on breach, not silently materialize
      # anything) without pretending a policy-driven cap already
      # exists.
      MATERIALIZE_CAP = 100_000

      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Stream", is_module: true)
        too_large = Helpers.fetch(legate, interp, "TooLarge")

        Builtins.define(cls, interp, "map") { |args, blk, _ncc| chain(args, blk, StreamOp::Kind::Map) }
        Builtins.define(cls, interp, "select") { |args, blk, _ncc| chain(args, blk, StreamOp::Kind::Select) }
        Builtins.define(cls, interp, "reject") { |args, blk, _ncc| chain(args, blk, StreamOp::Kind::Reject) }

        Builtins.define(cls, interp, "take") do |args, _blk, _ncc|
          n = (args[1]? || Value.nil_value).as_int.to_i32
          obj = args.first.as_robject.as(StreamObject)
          Value.robject(StreamObject.new(obj.rclass, obj.source, obj.ops + [StreamOp.new(StreamOp::Kind::Take, limit: n)]))
        end

        Builtins.define(cls, interp, "each") do |args, blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          if b = blk
            walk(obj, ncc) { |val| ncc.invoke(b, [val]) }
          end
          args.first
        end

        Builtins.define(cls, interp, "to_a") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          items = [] of Value
          walk(obj, ncc) do |val|
            if items.size >= MATERIALIZE_CAP
              ncc.raise_error_class("Legate::Stream#to_a — over #{MATERIALIZE_CAP} elements — use each_slice, top_by, or tally instead", too_large)
            end
            items << val
          end
          Value.new(LabeledArray.new(items), nil)
        end

        Builtins.define(cls, interp, "sum") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          sum(obj, ncc)
        end

        Builtins.define(cls, interp, "count") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          n = 0_i64
          walk(obj, ncc) { |_val| n += 1 }
          Value.int(n)
        end

        Builtins.define(cls, interp, "first") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          first(obj, ncc, args[1]?)
        end
      end

      # Builds a NEW stream sharing `args.first`'s underlying source
      # with one more pending op appended — see StreamObject's own
      # comment for why `blk` is captured, not invoked, here. No
      # block given: passes through unchanged (returns the receiver),
      # matching `Array#map`'s own established forgiving convention
      # (`array.cr`) rather than raising.
      private def self.chain(args : Array(Value), blk : ScriptProc?, kind : StreamOp::Kind) : Value
        return args.first unless blk
        obj = args.first.as_robject.as(StreamObject)
        Value.robject(StreamObject.new(obj.rclass, obj.source, obj.ops + [StreamOp.new(kind, block: blk)]))
      end

      # Pulls every remaining element through `obj`'s full op chain,
      # yielding each SURVIVING value — the one place actual iteration
      # happens; every terminal above is built on this. A `Take` op
      # sets `halt` once ITS limit is reached but does NOT stop mid-
      # chain — ops after it in the array still run for the element
      # that reached the limit (that element is legitimately within
      # the `take(n)` window); only the OUTER loop, after this
      # element is fully processed and yielded, refuses to pull any
      # FURTHER raw element at all. That "stop pulling upstream
      # entirely, don't just discard downstream" behavior is what
      # makes `take` genuinely lazy rather than merely a downstream
      # filter — confirmed against real Ruby's own
      # `Enumerator::Lazy#take`, which limits how many times it asks
      # ITS OWN upstream for a value, not how many results it discards
      # after the fact (an earlier draft got this backwards: `Take`
      # tripping only after already running every earlier op —
      # `map` included — on the (n+1)th element, letting the map
      # block's side effects fire on an element `take` should have
      # prevented from ever being pulled).
      private def self.walk(obj : StreamObject, ncc : NativeCallContext, & : Value ->) : Nil
        take_counts = Hash(Int32, Int32).new(0)
        loop do
          raw = obj.source.next
          break if raw.is_a?(Iterator::Stop)
          val = raw.as(Value)
          skip, halt = apply_ops(obj, ncc, val, take_counts) { |v| val = v }
          yield val unless skip
          break if halt
        end
      end

      # One element's pass through every op in the chain — split out
      # of `walk` purely to keep `walk` itself simple; `val` is
      # threaded through via the block param since a `Map` op replaces
      # it entirely, unlike `Select`/`Reject`/`Take` which only decide
      # skip/halt. `Select`/`Reject` short-circuit immediately (an
      # excluded element never reaches later ops at all — correct,
      # since it was never going to be yielded regardless); `Take`
      # does NOT short-circuit — it sets `halt` and lets the loop
      # keep running so ops positioned AFTER it in the chain still
      # apply to the element that reached the limit (see `walk`'s own
      # comment for why this distinction matters).
      private def self.apply_ops(obj : StreamObject, ncc : NativeCallContext, val : Value,
                                 take_counts : Hash(Int32, Int32), & : Value ->) : {Bool, Bool}
        halt = false
        obj.ops.each_with_index do |op, idx|
          case op.kind
          when .map?
            next unless block = op.block
            val = ncc.invoke(block, [val])
            yield val
          when .select?
            next unless block = op.block
            return {true, false} unless ncc.invoke(block, [val]).truthy?
          when .reject?
            next unless block = op.block
            return {true, false} if ncc.invoke(block, [val]).truthy?
          when .take?
            next unless limit = op.limit
            take_counts[idx] += 1
            halt = true if take_counts[idx] >= limit
          end
        end
        {false, halt}
      end

      private def self.sum(obj : StreamObject, ncc : NativeCallContext) : Value
        int_total = 0_i64
        float_total = 0.0
        saw_float = false
        walk(obj, ncc) do |val|
          if val.float?
            saw_float = true
            float_total += val.as_float
          else
            int_total += val.as_int
          end
        end
        saw_float ? Value.float(float_total + int_total) : Value.int(int_total)
      end

      # `first` (no arg) -> single element or nil; `first(n)` -> an
      # Array of up to n elements — real Ruby's own two-arity shape
      # for this method, not two different names.
      private def self.first(obj : StreamObject, ncc : NativeCallContext, count_arg : Value?) : Value
        if count_arg
          n = count_arg.as_int.to_i32
          items = [] of Value
          seen = 0
          walk(obj, ncc) do |val|
            items << val
            seen += 1
            break if seen >= n
          end
          Value.new(LabeledArray.new(items), nil)
        else
          result = Value.nil_value
          walk(obj, ncc) do |val|
            result = val
            break
          end
          result
        end
      end
    end
  end
end
