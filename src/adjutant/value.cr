module Adjutant
  # Discriminant for Value — determines which field of the raw storage is live.
  enum ValueTag
    Nil
    Bool
    Int
    Float
    String
    Symbol
    Array
    Hash
    Object
    Proc
    Class
    Range
  end

  # Raw storage for a Value.
  #
  # Crystal has no bare union type, so we hold all scalar slots together
  # and read only the field that matches the Value's tag.
  # Reference types are stored as Pointer(Void) in ptr.
  struct ValueRaw
    property i : Int64
    property f : Float64
    property b : Bool
    property ptr : Pointer(Void)

    def initialize
      @i = 0_i64
      @f = 0.0
      @b = false
      @ptr = Pointer(Void).null
    end
  end

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
    getter tag : ValueTag
    getter raw : ValueRaw
    getter label : SecurityLabel?

    # --- Constructors ---------------------------------------------------

    def self.nil_value : Value
      new(ValueTag::Nil, ValueRaw.new, nil)
    end

    def self.bool(b : Bool, label : SecurityLabel? = nil) : Value
      raw = ValueRaw.new
      raw.b = b
      new(ValueTag::Bool, raw, label)
    end

    def self.int(i : Int64, label : SecurityLabel? = nil) : Value
      raw = ValueRaw.new
      raw.i = i
      new(ValueTag::Int, raw, label)
    end

    def self.float(f : Float64, label : SecurityLabel? = nil) : Value
      raw = ValueRaw.new
      raw.f = f
      new(ValueTag::Float, raw, label)
    end

    def self.string(s : ::String, label : SecurityLabel? = nil) : Value
      raw = ValueRaw.new
      raw.ptr = Box.box(s)
      new(ValueTag::String, raw, label)
    end

    def self.symbol(s : ::String, label : SecurityLabel? = nil) : Value
      raw = ValueRaw.new
      raw.ptr = Box.box(s)
      new(ValueTag::Symbol, raw, label)
    end

    # --- Extractors -----------------------------------------------------

    def as_bool : Bool
      raw.b
    end

    def as_int : Int64
      raw.i
    end

    def as_float : Float64
      raw.f
    end

    def as_string : ::String
      Box(::String).unbox(raw.ptr)
    end

    def as_symbol : ::String
      Box(::String).unbox(raw.ptr)
    end

    # --- Predicates -----------------------------------------------------

    def null? : Bool
      tag == ValueTag::Nil
    end

    def truthy? : Bool
      case tag
      when ValueTag::Nil  then false
      when ValueTag::Bool then raw.b
      else                     true
      end
    end

    def falsy? : Bool
      !truthy?
    end

    # --- IFC ------------------------------------------------------------

    # Return a copy of this value with the given label attached.
    def with_label(l : SecurityLabel?) : Value
      Value.new(tag, raw, l)
    end

    # Return a copy of this value with the join of both labels.
    def join_label(other : Value) : Value
      joined = SecurityLabel.join(label, other.label)
      Value.new(tag, raw, joined)
    end

    # --- Display --------------------------------------------------------

    def to_s(io : IO) : Nil
      case tag
      when ValueTag::Nil    then io << "nil"
      when ValueTag::Bool   then io << raw.b
      when ValueTag::Int    then io << raw.i
      when ValueTag::Float  then io << raw.f
      when ValueTag::String then io << as_string
      when ValueTag::Symbol then io << ":" << as_symbol
      else                       io << "#<" << tag << ">"
      end
    end

    def inspect(io : IO) : Nil
      case tag
      when ValueTag::String then io << '"' << as_string << '"'
      when ValueTag::Symbol then io << ":" << as_symbol
      else                       to_s(io)
      end
      if l = label
        io << " [" << l << "]"
      end
    end

    # --- Private constructor --------------------------------------------

    protected def initialize(@tag : ValueTag, @raw : ValueRaw, @label : SecurityLabel?)
    end
  end
end
