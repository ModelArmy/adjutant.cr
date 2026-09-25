require "./risk_profile"

module Adjutant
  # A script's static risk, in the shape of its control flow, so that
  # exclusive branches aren't merged as if both ran. Built from the
  # AST, which keeps `if` and `case` apart for presentation.
  #
  #   Leaf:       one resolved call's RiskProfile.
  #   Sequence:   children that all run; `iterated` marks a loop body,
  #               which may repeat any number of times.
  #   Choice:     children of which exactly one runs (branches, `when`
  #               arms, rescue clauses against the body); aggregated as
  #               the worst member, naming which.
  #   Unresolved: a call the walker couldn't resolve, counted as
  #               Severity::Error. Adjutant has no dynamic dispatch, so
  #               these should be rare; frequent ones mean the walker
  #               needs work, not that the case should count for less.
  #   Deferred:   see RiskDeferred.
  abstract class RiskNode
    getter line : Int32

    def initialize(@line)
    end
  end

  class RiskLeaf < RiskNode
    getter profile : RiskProfile
    getter description : String

    def initialize(@profile, @description, line)
      super(line)
    end
  end

  class RiskSequence < RiskNode
    getter children : Array(RiskNode)
    getter? iterated : Bool

    def initialize(@children : Array(RiskNode), line, @iterated = false)
      super(line)
    end
  end

  class RiskChoice < RiskNode
    getter children : Array(RiskNode)
    getter origin : String # "if", "case", "rescue", etc. — for presentation

    def initialize(@children : Array(RiskNode), @origin, line)
      super(line)
    end
  end

  class RiskUnresolved < RiskNode
    getter description : String

    def initialize(@description, line)
      super(line)
    end
  end

  # A risk handed to a callee that may or may not run it: a lambda
  # passed as an argument. Its body is walked, but nothing shows the
  # callee calls it, unlike a block, which `yield` runs. "Deferred",
  # not "maybe", to keep it apart from RiskChoice, where one child
  # certainly runs.
  class RiskDeferred < RiskNode
    getter child : RiskNode
    getter reason : String

    def initialize(@child : RiskNode, @reason, line)
      super(line)
    end
  end
end
