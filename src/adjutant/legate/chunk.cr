require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"
require "./exceptions"

module Adjutant
  module Legate
    # `Legate::Chunk` — a byte-exact chunk yielded by `Legate::Bytes`
    # (LEGATE.md §4.2/§6, and a future byte-oriented network stream
    # the same way `Legate::EOF` was designed to generalize — see
    # stream.cr's own comment on that). NOT part of LEGATE.md as
    # originally written; invented this session to resolve a real gap
    # found while building `Legate.bytes`: Adjutant's `String` is
    # Crystal's own `String`, which MUST be valid UTF-8 as a language
    # invariant, so it cannot faithfully hold arbitrary binary content
    # the way real Ruby's `ASCII-8BIT`-tagged String can. See this
    # session's own design conversation for the fuller reasoning
    # (why a raw `ValueRaw` variant was considered and rejected in
    # favor of this — a Legate-scoped RubyObject, not a core-language
    # change — and why `Chunk` deliberately does NOT pretend to be a
    # `String`).
    #
    # Real Crystal-only state (`bytes : Bytes`, a genuine byte slice —
    # not representable in `ivars : Hash(Int32, Value)`, which can
    # only hold script-visible `Value`s), so this is a REAL RubyObject
    # SUBCLASS with its own field, the same shape as `TimeObject`/
    # `RegexpObject`/`StreamObject` — and inherits the SAME already-
    # documented `dup`/`clone`-loses-typed-state gap those carry
    # (SCOPE.md's Must Fix), not a new one this type introduces.
    #
    # No script-visible `.new` — broker-manufactured only via `.build`
    # below, same convention as every other Legate value type.
    #
    # Deliberately Array-shaped, not String-shaped, where the two
    # conventions would otherwise disagree: `#[](i)` returns a single
    # BYTE (an Integer 0–255), matching `Array#[]` on a byte sequence,
    # NOT `String#[]`'s own real-Ruby meaning (a substring). A model
    # reaching for `chunk[0]` expecting a one-character String would
    # get a clear, immediately-wrong-looking Integer rather than
    # silently-plausible-but-incorrect behavor — a loud mismatch is
    # recoverable; a silent one isn't. `#to_s`/`#to_a` are the two
    # explicit, clearly-named escape hatches into shapes a script
    # already knows how to work with (a real Adjutant String, once a
    # script vouches for the bytes being text; a plain Array of
    # Integer bytes, matching Ruby's own `String#bytes` convention)
    # rather than trying to make `Chunk` itself pass as either.
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

        # `scrub:` mirrors `Legate.read`'s own kwarg — see that verb's
        # comment on `String.new(Bytes)`'s substitution behavior being
        # unverified against a live toolchain; the same caveat applies
        # here, identically. Uses `define_native_method` directly
        # (not the `Builtins.define` shorthand every other method here
        # uses) since only the direct form accepts `kwarg_names`.
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

      # Crystal-facing constructor — every `Legate::Bytes` chunk pull
      # (verbs/bytes.cr) calls this directly; no script-visible path
      # to build one, matching every other Legate value type.
      def self.build(rclass : RubyClass, bytes : Bytes, label : RiskFlowLabel? = nil) : Value
        Value.robject(ChunkObject.new(rclass, bytes), label)
      end
    end
  end
end
