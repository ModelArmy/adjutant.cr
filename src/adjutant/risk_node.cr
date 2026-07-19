require "./risk_profile"

module Adjutant
  # Structured, static risk shape mirroring a script's control flow —
  # a sum-type-aware alternative to flattening every call site's
  # RiskProfile into one set of tags.
  #
  # Two other shapes were considered and rejected for v1:
  #   - A flat Array(RiskProfile): loses conditionality entirely (an
  #     if/else's two mutually-exclusive branches would merge into one
  #     tag set, as if both could happen in the same run).
  #   - Bytecode-level walk instead of AST: uniform Op::Jump shapes,
  #     but loses the source-level distinction between "if" and "case"
  #     the presentation layer wants, and requires reconstructing
  #     control-flow shape the AST already gives for free.
  #
  # RiskNode keeps the AST's shape:
  #   - Leaf       — one resolved call site's RiskProfile.
  #   - Sequence   — children that ALL occur (straight-line code,
  #                  loop bodies). `iterated` marks loop-body sequences,
  #                  since a script can't generally know its own
  #                  iteration count statically — presentation can say
  #                  "may repeat" without guessing a multiplier.
  #   - Choice     — children where exactly ONE occurs at runtime
  #                  (if/elsif/else branches, case/when arms, rescue
  #                  clauses vs. the protected body). Aggregating a
  #                  Choice takes the worst-case member rather than a
  #                  union, and the walker/aggregator should report
  #                  *which* branch carries that worst case, not just
  #                  the number.
  #   - Unresolved — a call site the walker couldn't statically
  #                  resolve to a NativeCallable or ScriptProc. Treated
  #                  as worst-case (Severity::Error) by the aggregator,
  #                  since a script language without dynamic dispatch
  #                  (see DEVELOPMENT.md "Forbidden features") should
  #                  make this rare; if it isn't, that's a sign the
  #                  walker or the forbidden-features list needs work,
  #                  not that this case should be silently downgraded.
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

  # A risk that was handed off to something the walker can't see into —
  # invocation isn't confirmed, only possible. Piece D (see SCOPE.md):
  # a `Lambda` literal or constant-held lambda passed as a call
  # argument is walked (so its body's risk IS known), but whether the
  # callee actually invokes it is outside the walker's visibility (no
  # confirmed `yield`-equivalent contract the way a BlockNode has via
  # `yield`) — folding it in unconditionally, the way a BlockNode's
  # risk folds into its call, would overstate risk for a lambda that's
  # merely stored/inspected/never called. Deliberately not named
  # "maybe"/"conditional": those read as branch semantics, easily
  # confused with RiskChoice (where exactly one child is guaranteed to
  # run) — "deferred" says the DECISION of whether this runs has been
  # handed elsewhere, which is the real mechanism.
  class RiskDeferred < RiskNode
    getter child : RiskNode
    getter reason : String

    def initialize(@child : RiskNode, @reason, line)
      super(line)
    end
  end
end
