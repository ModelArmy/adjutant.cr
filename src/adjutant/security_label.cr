module Adjutant
  # A security label attached to a Value for information flow control.
  #
  # Labels form a lattice. Currently a stub — name only.
  # The join operation (combining labels from two operands) will be
  # defined when the lattice is fleshed out in Phase 8.
  class SecurityLabel
    getter name : String

    def initialize(@name : String)
    end

    def to_s(io : IO) : Nil
      io << "label:" << @name
    end

    # Join two labels — returns the least upper bound in the lattice.
    # Stub: for now, labels on either side produce a combined label.
    def self.join(a : SecurityLabel?, b : SecurityLabel?) : SecurityLabel?
      return b if a.nil?
      return a if b.nil?
      return a if a.name == b.name
      new("#{a.name}+#{b.name}")
    end
  end
end
