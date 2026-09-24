module Adjutant
  # An Array(Value) with a mutable risk-flow label that accumulates
  # the labels of elements stored into it. A class, so every Value
  # holding the array shares one label; see research/IFC_DESIGN.md,
  # "Container labeling".
  #
  # Wraps rather than subclasses Array, whose methods build plain
  # Arrays and would drop the label. Doesn't include Indexable or
  # Enumerable: Value contains LabeledArray, and instantiating those
  # modules over the self-referential type crashes the compiler.
  class LabeledArray
    property label : RiskFlowLabel?

    def initialize(@items : Array(Value) = [] of Value, @label : RiskFlowLabel? = nil)
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

    def first : Value
      @items.first
    end

    def first? : Value?
      @items.first?
    end

    def last : Value
      @items.last
    end

    def last? : Value?
      @items.last?
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
      # Element-wise equality of two arrays of the same length.
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

    # A copy of the items, for building a new container; the caller
    # sets its label.
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

  # A Hash(Value, Value) with a mutable risk-flow label, as for
  # LabeledArray. `Enumerable({Value, Value})` is rejected by the
  # compiler, so iteration methods are written out. Keys may be
  # labelled: `Value#==` and `#hash` ignore labels.
  class LabeledHash
    property label : RiskFlowLabel?

    def initialize(@entries : Hash(Value, Value) = {} of Value => Value, @label : RiskFlowLabel? = nil)
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

    # Removes `key` and returns its value, or nil if absent, as Ruby's
    # `Hash#delete` does.
    def delete(key : Value) : Value?
      @entries.delete(key)
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

    # A copy of the entries, for building a new container; the caller
    # sets its label.
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
