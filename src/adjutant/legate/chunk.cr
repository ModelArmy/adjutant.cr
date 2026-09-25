require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"
require "./exceptions"

module Adjutant
  module Legate
    # `Legate::Chunk`: a byte-exact chunk from `Legate::Bytes`. An
    # addition to LEGATE.md, because Adjutant's String is Crystal's,
    # which must be valid UTF-8 and so can't hold arbitrary bytes. The
    # bytes live in a typed field; there is no script-visible `new`.
    #
    # Array-shaped, not String-shaped: `chunk[0]` is one byte as an
    # Integer, not a one-character String, so a script expecting text
    # gets a visibly wrong value rather than a plausible one. `to_s`
    # (decoding as UTF-8) and `to_a` (an Array of byte Integers) are the
    # ways out.
    module Chunk
      class ChunkObject < RubyObject
        property bytes : ::Bytes

        def initialize(rclass : RubyClass, @bytes : Bytes)
          super(rclass)
        end
      end

      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Chunk")
        malformed = Helpers.fetch(legate, interp, "Malformed")

        Builtins.define(cls, interp, "size") { |args| Value.int(obj_of(args).bytes.size.to_i64) }
        Builtins.define(cls, interp, "empty?") { |args| Value.bool(obj_of(args).bytes.size == 0) }

        Builtins.define(cls, interp, "[]") do |args|
          i = (args[1]? || Value.nil_value).as_int.to_i32
          bytes = obj_of(args).bytes
          i >= 0 && i < bytes.size ? Value.int(bytes[i].to_i64) : Value.nil_value
        end

        Builtins.define(cls, interp, "each_byte") do |args, blk, ncc|
          if b = blk
            obj_of(args).bytes.each { |byte| ncc.invoke(b, [Value.int(byte.to_i64)]) }
          end
          args.first
        end

        Builtins.define(cls, interp, "to_a") do |args|
          label = args.first.label
          items = obj_of(args).bytes.map { |byte| Value.int(byte.to_i64, label) }.to_a
          Value.new(LabeledArray.new(items, label), label)
        end

        # `to_s(scrub:)`, as `Legate.read` takes it. Registered with
        # `define_native_method`, the form that accepts `kwarg_names`.
        cls.define_native_method(
          interp.symbols.intern("to_s").value,
          RiskProfile.none,
          kwarg_names: Set{"scrub"},
        ) do |args, _blk, ncc|
          bytes = obj_of(args).bytes
          label = args.first.label
          scrub = (ncc.kwargs.try(&.["scrub"]?)).try(&.as_bool)
          scrub = true if scrub.nil?
          scrubbed = String.new(bytes)
          if !scrub && scrubbed.to_slice != bytes
            ncc.raise_error_class("Legate::Chunk#to_s: invalid UTF-8 byte sequence (scrub: false)", malformed)
          end
          Value.string(scrubbed, label)
        end

        Builtins.define(cls, interp, "+") do |args|
          a = obj_of(args).bytes
          b = (args[1]? || Value.nil_value).as_robject.as(ChunkObject).bytes
          combined = ::Bytes.new(a.size + b.size)
          combined.copy_from(a)
          (combined + a.size).copy_from(b)
          label = RiskFlowLabel.join(args.first.label, args[1]?.try(&.label))
          Value.robject(ChunkObject.new(args.first.as_robject.rclass, combined), label)
        end
      end

      private def self.obj_of(args : Array(Value)) : ChunkObject
        args.first.as_robject.as(ChunkObject)
      end

      # Builds a Chunk from Crystal code; `Legate.bytes` calls it for
      # each chunk it reads.
      def self.build(rclass : RubyClass, bytes : Bytes, label : RiskFlowLabel? = nil) : Value
        Value.robject(ChunkObject.new(rclass, bytes), label)
      end
    end
  end
end
