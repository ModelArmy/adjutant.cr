require "./risk_node"
require "./risk_profile"
require "./diagnostic"

module Adjutant
  # What a script could do on any run: every effect its RiskNode tree
  # can reach, with the worst severity, reversibility and iteration
  # found anywhere in it, each taken on its own. An upper bound, so no
  # single run need match it; `RiskAggregator.all_findings` says which
  # call contributes what.
  struct RiskSummary
    getter effects : Set(Effect)
    getter reversible : Reversibility
    getter severity : Severity
    getter? iterated : Bool # true if any part of the tree is a loop body

    def initialize(@effects, @reversible, @severity, @iterated)
    end

    def self.none : RiskSummary
      RiskSummary.new(Set(Effect).new, Reversibility::Yes, Severity::Info, false)
    end
  end

  # One leaf of a RiskNode tree, resolved or not, with where it sits:
  # `iterated` if inside a loop, `branch_path` for the branches that
  # lead to it. The same call weighs differently once, in a loop, or
  # only on one branch.
  struct RiskFinding
    getter description : String
    getter profile : RiskProfile
    getter line : Int32
    getter? iterated : Bool
    getter branch_path : Array(String) # e.g. ["if branch", "case branch"]

    def initialize(@description, @profile, @line, @iterated, @branch_path)
    end
  end

  # Reduces a RiskNode tree to every finding (`all_findings`) or to a
  # bound on every run (`summarize`).
  #
  # Worse means higher Severity (Error, Warning, Info), or less
  # reversible (No, Depends, Yes). An unresolved call counts as
  # ExecutesCode, Error and irreversible.
  module RiskAggregator
    # Every leaf and unresolved call in the tree. An unresolved call's
    # description starts "unresolved call: ". Grouping, filtering and
    # sorting are left to the presentation.
    def self.all_findings(node : RiskNode, iterated : Bool = false, branch_path : Array(String) = [] of String) : Array(RiskFinding)
      case node
      when RiskLeaf
        [RiskFinding.new(node.description, node.profile, node.line, iterated, branch_path)]
      when RiskUnresolved
        [RiskFinding.new("unresolved call: #{node.description}", unresolved_profile, node.line, iterated, branch_path)]
      when RiskSequence
        node.children.flat_map { |child| all_findings(child, iterated || node.iterated?, branch_path) }
      when RiskChoice
        node.children.flat_map { |child| all_findings(child, iterated, branch_path + ["#{node.origin} branch"]) }
      when RiskDeferred
        # A deferred risk counts in full, as unresolved ones do: what
        # can't be confirmed is surfaced, not discounted. Its
        # `branch_path` marks it deferred.
        all_findings(node.child, iterated, branch_path + ["deferred: #{node.reason}"])
      else
        [] of RiskFinding
      end
    end

    # The profile an unresolved call counts as, shared by both entry
    # points.
    private def self.unresolved_profile : RiskProfile
      RiskProfile.new(effects: Set{Effect::ExecutesCode}, reversible: Reversibility::No, severity: Severity::Error)
    end

    # The bound on every run of the tree. A Sequence and a Choice
    # combine their children alike, since a bound over branches of
    # which one runs is a bound over all of them. A deferred risk
    # counts in full.
    def self.summarize(node : RiskNode) : RiskSummary
      case node
      when RiskLeaf
        from_profile(node.profile)
      when RiskUnresolved
        from_profile(unresolved_profile)
      when RiskSequence
        combine(node.children, node.iterated?)
      when RiskChoice
        combine(node.children, false)
      when RiskDeferred
        summarize(node.child)
      else
        raise InternalError.new(
          Diagnostic.new(code: "I007", data: {"node" => node.class.to_s})
        )
      end
    end

    private def self.from_profile(profile : RiskProfile) : RiskSummary
      RiskSummary.new(profile.effects, profile.reversible, profile.severity, false)
    end

    # Unions the children's effects and takes the worst severity,
    # reversibility and iteration, each from whichever child has it.
    private def self.combine(children : Array(RiskNode), iterated : Bool) : RiskSummary
      return RiskSummary.none if children.empty?
      summaries = children.map { |child| summarize(child) }
      effects = Set(Effect).new
      summaries.each { |summary| effects.concat(summary.effects) }
      RiskSummary.new(
        effects,
        summaries.max_by { |summary| reversible_rank(summary.reversible) }.reversible,
        summaries.max_by { |summary| severity_rank(summary.severity) }.severity,
        iterated || summaries.any?(&.iterated?),
      )
    end

    private def self.severity_rank(sev : Severity) : Int32
      case sev
      when .error?   then 2
      when .warning? then 1
      else                0
      end
    end

    private def self.reversible_rank(rev : Reversibility) : Int32
      case rev
      when .no?      then 2
      when .depends? then 1
      else                0
      end
    end
  end
end
