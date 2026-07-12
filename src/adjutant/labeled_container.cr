module Adjutant
  # Wraps an Array(Value), adding a mutable SecurityLabel that
  # accumulates taint from elements set into it — see
  # research/IFC_DESIGN.md's "Container labeling (Stage 3.5)" section for
  # why this exists: Value is a struct, so a label living on a Value copy
  # popped off the stack has no way to persist back to the variable slot
  # a container came from. Putting the label on this wrapper instead
  # fixes that for free, since the wrapper (like the Array it held
  # before) is a reference type shared by every Value that wraps it.
  #
  # Composition, not inheritance: Array(Value) is not subclassed, because
  # Crystal's stdlib collection methods (map, select, dup, +, slicing,
  # ...) construct plain Array/Hash internally rather than `self.class.new`,
  # so a subclass would silently lose its label the moment any such
  # method ran.
  #
  # Hand-writes the small, fixed set of read/mutate methods actually
  # used elsewhere in the codebase (size, [], each, map, any?, zip,
  # push, pop, []=) rather than including Indexable(Value)/Enumerable.
  #
  # `include Indexable(Value)` was tried first but triggers a Crystal
  # compiler stack overflow (crystal 1.20.3) — Value's raw union
  # includes LabeledArray itself, so Value is a self-referential type,
  # and instantiating Indexable/Enumerable's generic methods over a
  # self-referential element type appears to blow up the compiler's
  # overload resolution. Hand-writing avoids the generic module
  # instantiation entirely — same fix already needed for LabeledHash's
  # `Enumerable({Value, Value})` attempt below, for a more directly
  # diagnosed reason (Value as a generic type argument is rejected
  # outright there; here it compiles but crashes — likely the same
  # underlying cause via a different code path).
  class LabeledArray
    property label : SecurityLabel?

    def initialize(@items : Array(Value) = [] of Value, @label : SecurityLabel? = nil)
    end

    def size : Int32
      @items.size
    end

    def empty? : Bool
      @items.empty?
    end

    def [](index : Int) : Value
      @items[index]
    end

    def []?(index : Int) : Value?
      @items[index]?
    end

    def each(& : Value ->) : Nil
      @items.each { |v| yield v }
    end

    def map(& : Value -> U) : Array(U) forall U
      @items.map { |v| yield v }
    end

    def any?(& : Value -> Bool) : Bool
      @items.any? { |v| yield v }
    end

    def to_a : Array(Value)
      @items.dup
    end

    def zip(other : LabeledArray, & : Value, Value -> Bool) : Bool
      # Only ever used (values_equal?) to check element-wise equality
      # of two same-length arrays — not a general zip, so this returns
      # the all?-style Bool the one real call site needs rather than an
      # array of tuples.
      @items.each_with_index.all? { |v, i| yield v, other[i] }
    end

    def push(value : Value) : LabeledArray
      @items.push(value)
      self
    end

    def pop : Value
      @items.pop
    end

    def pop? : Value?
      @items.pop?
    end

    def []=(index : Int, value : Value) : Value
      @items[index] = value
    end

    # Escape hatch for operations (e.g. `+`) that need a genuinely new,
    # independent Array(Value) to build a new container from — callers
    # are responsible for deciding that new container's label themselves
    # (typically SecurityLabel.join of the two sources' labels).
    def dup_items : Array(Value)
      @items.dup
    end

    def ==(other : LabeledArray) : Bool
      @items == other.@items
    end

    def hash(hasher)
      @items.hash(hasher)
    end
  end

  # Wraps a Hash(Value, Value), same rationale and shape as LabeledArray.
  # Crystal has no single Indexable-equivalent module for hash-like
  # types, and `include Enumerable({Value, Value})` hits a compiler
  # restriction ("can't use Value as a generic type argument yet"), so
  # the common read/iteration methods (including #all?, needed by
  # values_equal?'s hash case) are hand-written direct delegates instead
  # of coming from an included module.
  class LabeledHash
    property label : SecurityLabel?

    def initialize(@entries : Hash(Value, Value) = {} of Value => Value, @label : SecurityLabel? = nil)
    end

    def size : Int32
      @entries.size
    end

    def empty? : Bool
      @entries.empty?
    end

    def [](key : Value) : Value
      @entries[key]
    end

    def []?(key : Value) : Value?
      @entries[key]?
    end

    def []=(key : Value, value : Value) : Value
      @entries[key] = value
    end

    def has_key?(key : Value) : Bool
      @entries.has_key?(key)
    end

    def keys : Array(Value)
      @entries.keys
    end

    def values : Array(Value)
      @entries.values
    end

    def each(& : Value, Value ->) : Nil
      @entries.each { |k, v| yield k, v }
    end

    def all?(& : Value, Value -> Bool) : Bool
      @entries.all? { |k, v| yield k, v }
    end

    # Escape hatch for operations that need a genuinely new, independent
    # Hash(Value, Value) — see LabeledArray#dup_items.
    def dup_entries : Hash(Value, Value)
      @entries.dup
    end

    def ==(other : LabeledHash) : Bool
      @entries == other.@entries
    end

    def hash(hasher)
      @entries.hash(hasher)
    end
  end
end
