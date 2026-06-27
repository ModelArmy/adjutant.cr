module Adjutant
  # An interned symbol value.
  #
  # Symbols are interned by SymbolTable — every unique name gets exactly
  # one Sym instance with a stable integer ID. Comparisons use the ID
  # (O(1) integer compare) rather than the name string.
  struct Sym
    getter value : Int32
    getter name : String

    def initialize(@value, @name)
    end

    def ==(other : Sym) : Bool
      @value == other.value
    end

    def ==(other) : Bool
      false
    end

    def hash(hasher)
      @value.hash(hasher)
    end

    def to_s(io : IO) : Nil
      io << ':' << @name
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end

  # Interns symbol names and returns stable Sym instances.
  #
  # One SymbolTable per Interpreter instance — shared across all
  # compilations and VM executions within that interpreter so that
  # :foo always maps to the same Sym#value regardless of which script
  # introduced it first.
  class SymbolTable
    def initialize
      @table = {} of String => Sym
      @next_id = 0
    end

    # Return the Sym for name, creating it if not yet interned.
    def intern(name : String) : Sym
      @table[name] ||= begin
        sym = Sym.new(@next_id, name)
        @next_id += 1
        sym
      end
    end

    # Look up an existing Sym by name without interning.
    def lookup(name : String) : Sym?
      @table[name]?
    end

    # Look up a Sym by its integer ID — O(n) linear scan.
    # Only used for debugging/disassembly; not on the hot path.
    def name_for(id : Int32) : String?
      @table.each_value { |sym| return sym.name if sym.value == id }
      nil
    end

    def size : Int32
      @table.size
    end
  end
end
