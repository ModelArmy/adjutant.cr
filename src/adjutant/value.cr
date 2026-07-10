module Adjutant
  # The raw storage union for a Value.
  # Crystal's union type carries its own discriminant — no separate tag needed.
  alias ValueRaw = Nil | Bool | Int64 | Float64 | String | Sym | ScriptProc |
                   Array(Value) | Hash(Value, Value) | RubyClass | RubyObject

  # The core runtime value type for the Adjutant interpreter.
  #
  # Implemented as a struct so values are stack-allocated and copied
  # on assignment. This gives us:
  #   - No per-value heap allocation for scalars
  #   - Automatic label propagation on assignment (label travels with value)
  #   - Cache-friendly storage in arrays and frame locals
  #
  # The optional SecurityLabel reference is nil in the common unlabeled
  # case, adding only a pointer-width cost with a predictable nil check.
  struct Value
    getter raw : ValueRaw
    getter label : SecurityLabel?

    # --- Constructors ---------------------------------------------------

    def self.nil_value(label : SecurityLabel? = nil) : Value
      new(nil, label)
    end

    def self.bool(b : Bool, label : SecurityLabel? = nil) : Value
      new(b, label)
    end

    def self.int(i : Int64, label : SecurityLabel? = nil) : Value
      new(i, label)
    end

    def self.float(f : Float64, label : SecurityLabel? = nil) : Value
      new(f, label)
    end

    def self.string(s : String, label : SecurityLabel? = nil) : Value
      new(s, label)
    end

    def self.symbol(sym : Sym, label : SecurityLabel? = nil) : Value
      new(sym, label)
    end

    def self.proc(p : ScriptProc, label : SecurityLabel? = nil) : Value
      new(p, label)
    end

    def self.array(*values, label : SecurityLabel? = nil) : Value
      new(values.to_a, label)
    end

    def self.rclass(c : RubyClass, label : SecurityLabel? = nil) : Value
      new(c, label)
    end

    def self.robject(o : RubyObject, label : SecurityLabel? = nil) : Value
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
      @raw.is_a?(Array(Value))
    end

    def hash? : Bool
      @raw.is_a?(Hash(Value, Value))
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

    def as_array : Array(Value)
      @raw.as(Array(Value))
    end

    def as_hash : Hash(Value, Value)
      @raw.as(Hash(Value, Value))
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

    def as_array? : Array(Value)?
      @raw.as?(Array(Value))
    end

    def as_hash? : Hash(Value, Value)?
      @raw.as?(Hash(Value, Value))
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

    def with_label(l : SecurityLabel?) : Value
      Value.new(@raw, l)
    end

    def join_label(other : Value) : Value
      joined = SecurityLabel.join(label, other.label)
      Value.new(@raw, joined)
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
      when String     then io << '"' << r << '"'
      when Sym        then io << r
      when ScriptProc then io << "#<Proc>"
      else                 to_s(io)
      end
      if l = label
        io << " [" << l << "]"
      end
    end

    # --- Protected constructor ------------------------------------------

    protected def initialize(@raw : ValueRaw, @label : SecurityLabel?)
    end
  end
end
