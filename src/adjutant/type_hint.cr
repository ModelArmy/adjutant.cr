require "./ruby_class"

module Adjutant
  # Static type hint for one AST node's possible ValueRaw arm(s),
  # inferred without running the script. Feeds the risk walker's
  # Call-receiver resolution: a Call node can only become a RiskLeaf
  # (vs. RiskUnresolved) if its receiver's TypeHint is Known.
  #
  # `KnownType` holds a Set, not a single RubyClass, deliberately —
  # mirrors RiskNode's Choice/Sequence sum-type reasoning. A local
  # var reassigned a different type across if/else branches is a
  # real type union, not an inference failure; only genuinely
  # untraceable values (params, unresolved call returns) are Unknown.
  abstract class TypeHint
    def self.merge(a : TypeHint, b : TypeHint) : TypeHint
      return UnknownType.new if a.is_a?(UnknownType) || b.is_a?(UnknownType)
      KnownType.new(a.as(KnownType).classes | b.as(KnownType).classes)
    end
  end

  class KnownType < TypeHint
    getter classes : Set(RubyClass)

    def initialize(@classes : Set(RubyClass))
    end

    def initialize(single : RubyClass)
      @classes = Set{single}
    end

    def ==(other : KnownType) : Bool
      classes == other.classes
    end
  end

  class UnknownType < TypeHint
    def ==(other : UnknownType) : Bool
      true
    end
  end
end
