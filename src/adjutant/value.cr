module Adjutant
  # The raw storage union for a Value.
  # Crystal's union type carries its own discriminant — no separate tag needed.
  alias ValueRaw = Bool | Int64 | Float64 | String | Sym | ScriptProc |
                   LabeledArray | LabeledHash | RubyClass | RubyObject?

  # The restricted, native-Crystal subset a Value can coerce INTO via
  # `Value#to_plain`/`#to_plain?` — no RiskFlowLabel, no
  # LabeledArray/LabeledHash wrapper, no ScriptProc/RubyClass/
  # RubyObject. Deliberately shaped to match `Log::Metadata::Value::
  # Type` (Crystal's stdlib, `log/metadata.cr`) almost exactly — see
  # `Value#to_plain`'s own comment for why and for what a Sym/
  # RubyObject/etc. does when asked to become one of these.
  alias PlainValue = Bool | Int64 | Float64 | String |
                     Array(PlainValue) | Hash(String, PlainValue)?

  # The core runtime value type for the Adjutant interpreter.
  #
  # Implemented as a struct so values are stack-allocated and copied
  # on assignment. This gives us:
  #   - No per-value heap allocation for scalars
  #   - Automatic label propagation on assignment (label travels with value)
  #   - Cache-friendly storage in arrays and frame locals
  #
  # The optional RiskFlowLabel reference is nil in the common unlabeled
  # case, adding only a pointer-width cost with a predictable nil check.
  struct Value
    getter raw : ValueRaw

    # For scalar/non-container values this is just the stored label. For
    # array/hash values it defers to the live LabeledArray/LabeledHash's
    # own label instead of the field this Value struct was constructed
    # with — necessary because LabeledArray/LabeledHash#label can be
    # mutated after this Value was created (e.g. by a later SetIndex or
    # push elsewhere), and Value is a struct copied on every assignment,
    # so an old copy's own @label field would otherwise go stale. See
    # research/IFC_DESIGN.md's "Container labeling" section.
    def label : RiskFlowLabel?
      if arr = @raw.as?(LabeledArray)
        arr.label
      elsif h = @raw.as?(LabeledHash)
        h.label
      else
        @label
      end
    end

    # --- Equality / hashing (Crystal-level, NOT Ruby's own ==) ---------

    # Deliberately compares/hashes ONLY `@raw`, ignoring `@label`
    # entirely — WITHOUT this override, `struct`'s default
    # field-by-field equality/hash would include `@label`, which
    # breaks the moment this `Value` is used as a Crystal `Hash` key
    # (every script-level Ruby `Hash` literal's own internal storage,
    # `hash.cr`'s own comment confirms — Crystal's `Hash(Value,
    # Value)#[]` hashes via exactly this method) with a LABELED key: a
    # freshly-constructed unlabeled lookup key would silently fail to
    # match a differently-labeled stored key, returning a false `nil`
    # rather than an error. Found 2026-08-24 in
    # `Legate::Response#json`'s own construction of a decoded-JSON
    # Hash (`legate/response.cr`) — fixed there by simply not labeling
    # keys, but that's a convention a future native-code author could
    # easily forget; this is the real, permanent fix, removing the
    # whole class of bug rather than relying on everyone remembering
    # not to trip over it (see `LabeledHash`'s own comment,
    # `labeled_container.cr`, which predates this fix and is still
    # worth reading for the full story).
    #
    # Matches Adjutant's own SCRIPT-VISIBLE `==` semantics
    # (`ValueOps.equal?`) on purpose: real Ruby's hash-key equality has
    # nothing to do with taint, and a label making two otherwise-
    # identical values act as different dictionary keys would itself
    # have been a second, independent bug. For the overwhelming
    # majority of values (unlabeled — `@label` is `nil` on both sides
    # already) this changes nothing; for container values (`raw` is a
    # `LabeledArray`/`LabeledHash`, a REFERENCE type), Crystal's
    # default reference equality/hash already ignores the STRUCT's own
    # `@label` field in favor of object identity, so this override is
    # a no-op there too — the only real behavior change is for
    # LABELED scalars/objects, exactly the case that was broken.
    def ==(other : Value) : Bool
      @raw == other.raw
    end

    # NOTE ON VERIFICATION: Crystal's struct-hash-override convention
    # (`def hash(hasher)`, delegating to `@raw.hash(hasher)`) is
    # written from recollection, not independently confirmed against
    # a live toolchain here — same caveat this codebase already
    # attaches to other Crystal stdlib API assumptions
    # (`builtins/regexp.cr`, `builtins/time.cr`). If `ops build`
    # reports a signature mismatch, this is the first place to look;
    # the INTENT (hash by `@raw` alone, ignore `@label`) is what's
    # actually load-bearing here, not this exact method signature.
    def hash(hasher)
      @raw.hash(hasher)
    end

    # --- Constructors ---------------------------------------------------

    def self.nil_value(label : RiskFlowLabel? = nil) : Value
      new(nil, label)
    end

    def self.bool(b : Bool, label : RiskFlowLabel? = nil) : Value
      new(b, label)
    end

    def self.int(i : Int, label : RiskFlowLabel? = nil) : Value
      new(i.to_i64, label)
    end

    def self.int(f : Float, label : RiskFlowLabel? = nil) : Value
      new(f.to_i64, label)
    end

    def self.float(f : Float64, label : RiskFlowLabel? = nil) : Value
      new(f, label)
    end

    def self.float(i : Int, label : RiskFlowLabel? = nil) : Value
      new(i.to_f64, label)
    end

    def self.string(s : String, label : RiskFlowLabel? = nil) : Value
      new(s, label)
    end

    def self.symbol(sym : Sym, label : RiskFlowLabel? = nil) : Value
      new(sym, label)
    end

    def self.proc(p : ScriptProc, label : RiskFlowLabel? = nil) : Value
      new(p, label)
    end

    def self.array(*values, label : RiskFlowLabel? = nil) : Value
      new(LabeledArray.new(values.to_a, label), label)
    end

    def self.rclass(c : RubyClass, label : RiskFlowLabel? = nil) : Value
      new(c, label)
    end

    def self.robject(o : RubyObject, label : RiskFlowLabel? = nil) : Value
      new(o, label)
    end

    # --- Type predicates ------------------------------------------------

    def null? : Bool
      @raw.nil?
    end

    def bool? : Bool
      @raw.is_a?(Bool)
    end

    def int? : Bool
      @raw.is_a?(Int64)
    end

    def float? : Bool
      @raw.is_a?(Float64)
    end

    def string? : Bool
      @raw.is_a?(String)
    end

    def symbol? : Bool
      @raw.is_a?(Sym)
    end

    def array? : Bool
      @raw.is_a?(LabeledArray)
    end

    def hash? : Bool
      @raw.is_a?(LabeledHash)
    end

    def proc? : Bool
      @raw.is_a?(ScriptProc)
    end

    def rclass? : Bool
      @raw.is_a?(RubyClass)
    end

    def robject? : Bool
      @raw.is_a?(RubyObject)
    end

    # --- Extractors -----------------------------------------------------

    def as_bool : Bool
      @raw.as(Bool)
    end

    def as_int : Int64
      @raw.as(Int64)
    end

    def as_float : Float64
      @raw.as(Float64)
    end

    def as_string : String
      @raw.as(String)
    end

    def as_sym : Sym
      @raw.as(Sym)
    end

    def as_array : LabeledArray
      @raw.as(LabeledArray)
    end

    def as_hash : LabeledHash
      @raw.as(LabeledHash)
    end

    def as_proc : ScriptProc
      @raw.as(ScriptProc)
    end

    def as_rclass : RubyClass
      @raw.as(RubyClass)
    end

    def as_robject : RubyObject
      @raw.as(RubyObject)
    end

    # --- Testing extractors -----------------------------------------------------

    def as_bool? : Bool?
      @raw.as?(Bool)
    end

    def as_int? : Int64?
      @raw.as?(Int64)
    end

    def as_float? : Float64?
      @raw.as?(Float64)
    end

    def as_string? : String?
      @raw.as?(String)
    end

    def as_sym? : Sym?
      @raw.as?(Sym)
    end

    def as_array? : LabeledArray?
      @raw.as?(LabeledArray)
    end

    def as_hash? : LabeledHash?
      @raw.as?(LabeledHash)
    end

    def as_proc? : ScriptProc?
      @raw.as?(ScriptProc)
    end

    def as_rclass? : RubyClass?
      @raw.as?(RubyClass)
    end

    def as_robject? : RubyObject?
      @raw.as?(RubyObject)
    end

    # --- Plain conversion -------------------------------------------------

    # How deep `to_plain`/`to_plain?` will recurse into nested
    # Arrays/Hashes before giving up. A script builds these
    # PROGRAMMATICALLY (`h = {} of Value => Value; 100_000.times { h
    # = wrap(h) }`), not just by literal nesting in source text, so
    # "how deeply can a script's own source nest a literal" is not a
    # bound on how deep the actual VALUE can get — this recursion is
    # plain Crystal call-stack recursion, not the VM's own
    # frame-tracked, `call_depth_limit`-guarded kind, so it needs its
    # own bound or a script can drive it into a real Crystal stack
    # overflow. 32 is comfortably past any legitimate structured-
    # logging payload and comfortably short of where that becomes a
    # risk.
    PLAIN_MAX_DEPTH = 32

    # Recursively converts this Value into `PlainValue` — nil,
    # true/false, an Integer, a Float, a String, or an Array/Hash of
    # the same — or raises if it has no such representation. `to_plain?`
    # below is the nil-on-failure counterpart, matching this
    # codebase's own `as_int`/`as_int?`-style pairing (raise vs nil),
    # just extended to a conversion that can fail partway through a
    # container rather than only at the top.
    #
    # EXTRACTED here (not written directly into `legate/verbs/log.cr`,
    # its first real caller) because "give me the plain form of this
    # Value, if it has one" is a general enough question — the next
    # native/builtin author needing the same thing (structured error
    # data, an embedder-facing inspection API, some future non-Legate
    # provider) should find it on `Value` itself rather than writing a
    # second, silently-drifting copy. Mirrors `Legate::Helpers.
    # json_to_value`'s own reasoning for being shared (`legate/
    # helpers.cr`) — same shape of problem, opposite direction.
    #
    # A `Sym` coerces to its `name` — neither `Log::Metadata` nor JSON
    # has a Symbol variant, and refusing to represent `status: :ok` as
    # `status: "ok"` would cost real ergonomics for no benefit; the
    # distinction between a Symbol and a String is a Ruby-level
    # concern that has nothing left to say once the value leaves the
    # interpreter entirely, which is exactly what this conversion is
    # for. This applies to a Hash's KEYS too, not just plain values —
    # `{ok: true}` is exactly as common a Ruby literal as `{"ok" =>
    # true}`, and a NESTED Hash (a value inside another Hash/Array
    # being converted) hits this just as often as a top-level one.
    # Found missing here, 2026-09-08, by a spec that nested a
    # Symbol-keyed Hash inside `Legate.log`'s `fields` argument
    # (`legate/verbs/log_spec.cr`) — `Legate::Verbs::Log.fields_of`
    # already accepted either spelling for `fields`' OWN keys, but
    # this method, which every key one level deeper actually goes
    # through, did not yet. `ScriptProc`, `RubyClass`, and
    # `RubyObject` all raise
    # rather than falling back to some `#inspect`-shaped string:
    # LEGATE.md's own "no implicit #to_s" stance (`write_io_piece`,
    # `legate/helpers.cr`) applies here too — an arbitrary object's
    # default representation silently ending up in a log line (or
    # wherever else a future caller sends `to_plain`'s result) is more
    # surprising than making the caller convert explicitly, and unlike
    # a String/Symbol/number there is no single unsurprising fallback
    # — producing one would mean dispatching a real method call
    # (`#to_s`, possibly script-overridden), with everything that
    # implies about `NativeCallContext` and reentrancy, which this
    # plain Crystal struct method has no way to do and should not
    # start trying to.
    def to_plain(depth : Int32 = 0) : PlainValue
      raise ArgumentError.new("Value#to_plain: nesting exceeds #{PLAIN_MAX_DEPTH}") if depth > PLAIN_MAX_DEPTH

      case r = @raw
      when Nil, Bool, Int64, Float64, String
        r
      when Sym
        r.name
      when LabeledArray
        # Built into an explicitly `[] of PlainValue`-typed Array,
        # NOT `r.map(&.to_plain(depth + 1))` — tried first, and
        # rejected by the compiler: `LabeledArray#map`'s generic
        # `forall U` infers `U` as the fully expanded recursive union
        # rather than folding it back into the `PlainValue` alias
        # name, and Crystal's return-type check treats that expanded
        # union as a mismatch against the declared `PlainValue`
        # return type even though they're the same type structurally.
        # Confirmed against a live `crystal build`, 2026-09-08 — the
        # Hash branch just below was already written this same
        # explicit-container way and compiled fine the first time,
        # which is why only this branch needed the fix.
        out = [] of PlainValue
        r.each { |item| out << item.to_plain(depth + 1) }
        out
      when LabeledHash
        out = {} of String => PlainValue
        r.each do |k, v|
          key_name = if k.string?
                       k.as_string
                     elsif k.symbol?
                       k.as_sym.name
                     else
                       raise ArgumentError.new("Value#to_plain: Hash key #{k.inspect} is neither a String nor a Symbol")
                     end
          out[key_name] = v.to_plain(depth + 1)
        end
        out
      else
        raise ArgumentError.new("Value#to_plain: #{r.class} has no plain representation")
      end
    end

    def to_plain? : PlainValue?
      to_plain
    rescue ArgumentError
      nil
    end

    # --- Truthiness -----------------------------------------------------

    def truthy? : Bool
      case @raw
      when Nil  then false
      when Bool then @raw.as(Bool)
      else           true
      end
    end

    def falsy? : Bool
      !truthy?
    end

    # --- IFC ------------------------------------------------------------

    # For scalars, attaches the given label to a new Value. For
    # array/hash values, sets the label on the underlying
    # LabeledArray/LabeledHash directly (mutating it in place, visible
    # to every Value referencing the same container) rather than on a
    # field the computed #label getter above would ignore.
    def with_label(l : RiskFlowLabel?) : Value
      if arr = @raw.as?(LabeledArray)
        arr.label = l
        return self
      end
      if h = @raw.as?(LabeledHash)
        h.label = l
        return self
      end
      Value.new(@raw, l)
    end

    def join_label(other : Value) : Value
      with_label(RiskFlowLabel.join(label, other.label))
    end

    # --- Display --------------------------------------------------------

    def to_s(io : IO) : Nil
      case r = @raw
      when Nil        then nil # real Ruby: nil.to_s == "" — write nothing
      when Bool       then io << r
      when Int64      then io << r
      when Float64    then io << r
      when String     then io << r
      when Sym        then io << r
      when ScriptProc then io << "#<Proc>"
      when RubyClass  then io << r
      when RubyObject then io << r
      else                 io << "#<" << @raw.class << ">"
      end
    end

    def inspect(io : IO) : Nil
      case r = @raw
      when Nil        then io << "nil"
      when String     then inspect_string(io, r)
      when Sym        then io << r
      when ScriptProc then io << "#<Proc>"
      else                 to_s(io)
      end
      if l = label
        io << " [" << l << "]"
      end
    end

    # Real Ruby's `String#inspect` escapes `"`/`\` (needed for the
    # output to even be valid re-quoted syntax at all) plus at least
    # `\n`/`\t` (extremely common, unambiguous, low-risk to include).
    # Found 2026-08-17: the PREVIOUS version of this method did none
    # of that — `io << '"' << r << '"'`, no escaping whatsoever — a
    # real, foundational bug (not specific to any one caller): ANY
    # String containing a literal `"` rendered as genuinely invalid,
    # unparseable output wherever `#inspect` was used, not just
    # MatchData's own new `#inspect` (regexp_spec.cr) that happened to
    # be the first thing to actually assert on the escaped content
    # rather than just "some string came back." Deliberately NOT a
    # full implementation of every escape real Ruby's own
    # `String#inspect` produces (`\e`, `\0`, `\a`, `\b`, `\f`, `\v`,
    # non-ASCII/invalid-encoding handling, ...) — those are real,
    # separate, lower-confidence gaps, not folded in here without a
    # way to verify each one directly.
    private def inspect_string(io : IO, r : String) : Nil
      io << '"'
      r.each_char do |char|
        case char
        when '"'  then io << "\\\""
        when '\\' then io << "\\\\"
        when '\n' then io << "\\n"
        when '\t' then io << "\\t"
        else           io << char
        end
      end
      io << '"'
    end

    # --- Protected constructor ------------------------------------------

    protected def initialize(@raw : ValueRaw, @label : RiskFlowLabel?)
    end
  end
end
