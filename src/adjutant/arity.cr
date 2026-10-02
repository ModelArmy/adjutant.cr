module Adjutant
  # How many positional arguments a method or lambda accepts, counted
  # as Ruby counts them: without the receiver, the block or keywords.
  # `max` is nil when there is no upper bound, as with a splat.
  struct Arity
    getter min : Int32
    getter max : Int32?

    def initialize(@min : Int32, @max : Int32?)
    end

    # Any number of arguments, for a host function that checks its own.
    def self.any : Arity
      new(0, nil)
    end

    # Exactly `count` arguments.
    def self.from(count : Int32) : Arity
      new(count, count)
    end

    # `1..2` accepts one or two arguments.
    def self.from(range : Range(Int32, Int32)) : Arity
      new(range.begin, range.excludes_end? ? range.end - 1 : range.end)
    end

    # `(1..)` accepts one or more.
    def self.from(range : Range(Int32, Nil)) : Arity
      new(range.begin, nil)
    end

    def self.from(arity : Arity) : Arity
      arity
    end

    def accepts?(count : Int32) : Bool
      return false if count < @min
      max = @max
      max.nil? || count <= max
    end

    # What Ruby's ArgumentError says is expected: `2`, `1..2` or `1+`.
    def to_s(io : IO) : Nil
      io << @min
      max = @max
      if max.nil?
        io << '+'
      elsif max != @min
        io << ".." << max
      end
    end
  end

  # What a native registration accepts as its arity: `0`, `0..1`,
  # `(1..)` or an Arity.
  alias ArityLike = Int32 | Range(Int32, Int32) | Range(Int32, Nil) | Arity
end
