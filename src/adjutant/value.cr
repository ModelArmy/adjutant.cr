module Adjutant
  # The raw storage union for a Value.
  # Crystal's union type carries its own discriminant — no separate tag needed.
  alias ValueRaw = Bool | Int64 | Float64 | String | Sym | ScriptProc |
                   LabeledArray | LabeledHash | RubyClass | RubyObject?

  # What a Value converts to with `Value#to_plain`: plain Crystal
  # data with no labels, wrappers, procs, classes or objects. Shaped to
  # match Crystal's `Log::Metadata::Value::Type`.
  alias PlainValue = Bool | Int64 | Float64 | String |
                     Array(PlainValue) | Hash(String, PlainValue)?

  # A script value: its raw data plus an optional risk-flow label.
  # A struct, so scalars need no heap allocation and the label is
  # copied along with the value on every assignment.
  struct Value
    getter raw : ValueRaw

    # The value's risk-flow label. An Array or Hash reports its
    # container's current label, which later mutation can change, not
    # the one this struct copy was made with.
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

    # Compares and hashes `@raw` alone, ignoring the label, so a
    # labelled key and an unlabelled lookup key match in a Crystal
    # `Hash(Value, Value)`, as they do for Ruby's `==`.
    def ==(other : Value) : Bool
      @raw == other.raw
    end

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

    # How deep `to_plain` recurses into nested Arrays and Hashes. The
    # recursion uses the Crystal stack, not the VM's depth-limited
    # frames, and a script can build nesting of any depth at runtime.
    PLAIN_MAX_DEPTH = 32

    # Converts this Value to a `PlainValue`, recursing into Arrays and
    # Hashes, or raises `ArgumentError`. A Symbol becomes its name;
    # Hash keys must be Strings or Symbols. A Proc, class or object
    # raises rather than being rendered, since rendering it would mean
    # calling its `to_s`. `to_plain?` returns nil instead of raising.
    def to_plain(depth : Int32 = 0) : PlainValue
      raise ArgumentError.new("Value#to_plain: nesting exceeds #{PLAIN_MAX_DEPTH}") if depth > PLAIN_MAX_DEPTH

      case r = @raw
      when Nil, Bool, Int64, Float64, String
        r
      when Sym
        r.name
      when LabeledArray
        # Built explicitly: `r.map` infers the expanded union type,
        # which Crystal rejects as a `PlainValue` return.
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

    # Escapes `"`, `\`, newline and tab. Ruby's other escapes (`\e`,
    # `\0`, non-ASCII and so on) are not produced.
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
