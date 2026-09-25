require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

# One pending operation in a stream's chain: the block given to `map`,
# `select`, `reject` or `take`, run later by whichever terminal walks
# the chain, with that terminal's NativeCallContext.
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

  # Whether a stream's source has returned `Iterator::Stop`, shared by
  # every stream derived from the same source (LEGATE.md §6.1). It
  # records physical exhaustion, not whether a terminal has run:
  # `a = s.select {}; b = s.select {}; a.first(2); b.to_a` is one walk
  # continued, and only a terminal that starts after the source ran
  # dry raises `Legate::EOF`.
  class StreamConsumption
    property? exhausted : Bool = false
  end

  # A stream: a Crystal `Iterator(Value)` source and the pending ops
  # not yet applied. `map`, `select`, `reject` and `take` return a new
  # StreamObject over the same source with one more op, so streams
  # derived from a common ancestor share its pull position, as lazy
  # enumerators over one IO do in Ruby.
  class StreamObject < RubyObject
    property source : Iterator(Value)
    property ops : Array(StreamOp)
    property state : StreamConsumption

    def initialize(rclass : RubyClass, @source : Iterator(Value), @ops : Array(StreamOp) = [] of StreamOp,
                   @state : StreamConsumption = StreamConsumption.new)
      super(rclass)
    end
  end

  module Legate
    # `Legate::Stream` (LEGATE.md §6), a module included by the concrete
    # stream types (`Lines`, `Bytes`, `Records`). Lazy, like Ruby's
    # `Enumerator::Lazy`: `map` returns a stream and nothing runs until
    # a terminal walks it. Implements `map`, `select`, `reject`,
    # `take`, `each`, `to_a`, `first`, `sum` and `count`; the rest of
    # §6.2 to §6.4 isn't built.
    module Stream
      # How many elements a materialising terminal (`to_a`) may collect
      # before raising `Legate::TooLarge`. A fixed count standing in for
      # §6.4's policy memory cap.
      MATERIALIZE_CAP = 100_000

      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Stream", is_module: true)
        too_large = Helpers.fetch(legate, interp, "TooLarge")
        eof = Helpers.fetch(legate, interp, "EOF")

        Builtins.define(cls, interp, "map") { |args, blk, _ncc| chain(args, blk, StreamOp::Kind::Map) }
        Builtins.define(cls, interp, "select") { |args, blk, _ncc| chain(args, blk, StreamOp::Kind::Select) }
        Builtins.define(cls, interp, "reject") { |args, blk, _ncc| chain(args, blk, StreamOp::Kind::Reject) }

        Builtins.define(cls, interp, "take") do |args, _blk, _ncc|
          n = (args[1]? || Value.nil_value).as_int.to_i32
          obj = args.first.as_robject.as(StreamObject)
          Value.robject(StreamObject.new(obj.rclass, obj.source, obj.ops + [StreamOp.new(StreamOp::Kind::Take, limit: n)], obj.state))
        end

        Builtins.define(cls, interp, "each") do |args, blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          if b = blk
            walk(obj, ncc, eof) { |val| ncc.invoke(b, [val]) }
          end
          args.first
        end

        Builtins.define(cls, interp, "to_a") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          items = [] of Value
          walk(obj, ncc, eof) do |val|
            if items.size >= MATERIALIZE_CAP
              ncc.raise_error_class("Legate::Stream#to_a — over #{MATERIALIZE_CAP} elements — use each_slice, top_by, or tally instead", too_large)
            end
            items << val
          end
          # The Array's label joins every element's.
          label = Builtins.joined_label(items)
          Value.new(LabeledArray.new(items, label), label)
        end

        Builtins.define(cls, interp, "sum") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          sum(obj, ncc, eof)
        end

        Builtins.define(cls, interp, "count") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          n = 0_i64
          walk(obj, ncc, eof) { |_val| n += 1 }
          Value.int(n)
        end

        Builtins.define(cls, interp, "first") do |args, _blk, ncc|
          obj = args.first.as_robject.as(StreamObject)
          first(obj, ncc, eof, args[1]?)
        end
      end

      # A new stream over the same source with one more op, `blk`
      # stored rather than run. Without a block, returns the receiver.
      private def self.chain(args : Array(Value), blk : ScriptProc?, kind : StreamOp::Kind) : Value
        return args.first unless blk
        obj = args.first.as_robject.as(StreamObject)
        Value.robject(StreamObject.new(obj.rclass, obj.source, obj.ops + [StreamOp.new(kind, block: blk)], obj.state))
      end

      # Pulls each remaining element through the op chain and yields
      # the ones that survive; every terminal is built on this, and it
      # is the public seam for a verb to consume a stream one element at
      # a time, as `Legate.write` does so a pipeline never materialises
      # (§4.3). A `take` that reaches its limit stops further pulls from
      # the source, while ops after it still apply to the element that
      # reached it, as `Enumerator::Lazy#take` does, so later blocks
      # never run on an element `take` excluded. Raises `eof`
      # (`Legate::EOF`) if the source was already exhausted when the
      # walk began (§6.1).
      def self.walk(obj : StreamObject, ncc : NativeCallContext, eof : RubyClass, & : Value ->) : Nil
        ncc.raise_error_class("Legate::Stream — source already exhausted; this stream is single-pass. Call Legate.lines/bytes/records again to re-read.", eof) if obj.state.exhausted?

        take_counts = Hash(Int32, Int32).new(0)
        loop do
          raw = obj.source.next
          if raw.is_a?(Iterator::Stop)
            obj.state.exhausted = true
            break
          end
          val = raw.as(Value)
          skip, halt = apply_ops(obj, ncc, val, take_counts) { |v| val = v }
          yield val unless skip
          break if halt
        end
      end

      # One element through every op, yielding the result if it
      # survives. `select` and `reject` stop at an excluded element;
      # `take` sets `halt` and lets later ops run.
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

      # The label joins every summed element's.
      private def self.sum(obj : StreamObject, ncc : NativeCallContext, eof : RubyClass) : Value
        int_total = 0_i64
        float_total = 0.0
        saw_float = false
        labels = [] of Value
        walk(obj, ncc, eof) do |val|
          labels << val
          if val.float?
            saw_float = true
            float_total += val.as_float
          else
            int_total += val.as_int
          end
        end
        label = Builtins.joined_label(labels)
        saw_float ? Value.float(float_total + int_total, label) : Value.int(int_total, label)
      end

      # `first` gives one element, carrying its own label, or nil;
      # `first(n)` an Array of up to `n`, labelled as `to_a` labels.
      private def self.first(obj : StreamObject, ncc : NativeCallContext, eof : RubyClass, count_arg : Value?) : Value
        if count_arg
          n = count_arg.as_int.to_i32
          items = [] of Value
          seen = 0
          walk(obj, ncc, eof) do |val|
            items << val
            seen += 1
            break if seen >= n
          end
          label = Builtins.joined_label(items)
          Value.new(LabeledArray.new(items, label), label)
        else
          result = Value.nil_value
          walk(obj, ncc, eof) do |val|
            result = val
            break
          end
          result
        end
      end
    end
  end
end
