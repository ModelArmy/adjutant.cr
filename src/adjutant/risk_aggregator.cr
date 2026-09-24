require "./risk_node"
require "./risk_profile"
require "./diagnostic"

module Adjutant
  # The worst-case path through a RiskNode tree, as a trail of
  # descriptions: "delete_file (inside if branch: ...)", so a report
  # can say why, not just how bad.
  struct RiskSummary
    getter effects : Set(Effect)
    getter reversible : Reversibility
    getter severity : Severity
    getter path : Array(String) # trail of descriptions/origins, root to leaf
    getter? iterated : Bool     # true if any Sequence on the worst path was iterated

    def initialize(@effects, @reversible, @severity, @path, @iterated)
    end

    def self.none : RiskSummary
      RiskSummary.new(Set(Effect).new, Reversibility::Yes, Severity::Info, [] of String, false)
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

  # Reduces a RiskNode tree to every finding (`all_findings`) or to
  # the single worst path (`summarize`), which takes the worst branch
  # of a Choice rather than a union of exclusive branches.
  #
  # Worse means higher Severity (Error, Warning, Info), then less
  # reversible (No, Depends, Yes). Unresolved outranks everything.
  module RiskAggregator
    # Every leaf and unresolved call in the tree. Grouping, filtering
    # and sorting are left to the presentation.
    def self.all_findings(node : RiskNode, iterated : Bool = false, branch_path : Array(String) = [] of String) : Array(RiskFinding)
      case node
      when RiskLeaf
        [RiskFinding.new(node.description, node.profile, node.line, iterated, branch_path)]
      when RiskUnresolved
        [RiskFinding.new(node.description, unresolved_profile, node.line, iterated, branch_path)]
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

    def self.summarize(node : RiskNode) : RiskSummary
      case node
      when RiskLeaf
        RiskSummary.new(node.profile.effects, node.profile.reversible, node.profile.severity,
          [node.description], false)
      when RiskUnresolved
        p = unresolved_profile
        RiskSummary.new(p.effects, p.reversible, p.severity,
          ["unresolved call: #{node.description}"], false)
      when RiskSequence
        summarize_sequence(node)
      when RiskChoice
        summarize_choice(node)
      when RiskDeferred
        summarize_deferred(node)
      else
        raise InternalError.new(
          Diagnostic.new(code: "I007", data: {"node" => node.class.to_s})
        )
      end
    end

    # Every child runs: effects are unioned, the worst severity and
    # reversibility win, and the paths are concatenated.
    private def self.summarize_sequence(node : RiskSequence) : RiskSummary
      return RiskSummary.none if node.children.empty?
      child_summaries = node.children.map { |child| summarize(child) }
      effects = Set(Effect).new
      child_summaries.each { |summary| effects.concat(summary.effects) }
      worst = child_summaries.max_by { |summary| rank(summary) }
      RiskSummary.new(
        effects,
        worst.reversible,
        worst.severity,
        child_summaries.flat_map(&.path),
        node.iterated? || child_summaries.any?(&.iterated?),
      )
    end

    # One child runs: the worst branch, tagged with which it was.
    private def self.summarize_choice(node : RiskChoice) : RiskSummary
      return RiskSummary.none if node.children.empty?
      child_summaries = node.children.map { |child| summarize(child) }
      worst = child_summaries.max_by { |summary| rank(summary) }
      RiskSummary.new(
        worst.effects,
        worst.reversible,
        worst.severity,
        ["#{node.origin} branch"] + worst.path,
        worst.iterated?,
      )
    end

    # The child's risk counts in full; the path is prefixed
    # "deferred: <reason>", since it runs only if a callee invokes
    # what it was given.
    private def self.summarize_deferred(node : RiskDeferred) : RiskSummary
      child_summary = summarize(node.child)
      RiskSummary.new(
        child_summary.effects,
        child_summary.reversible,
        child_summary.severity,
        ["deferred: #{node.reason}"] + child_summary.path,
        child_summary.iterated?,
      )
    end

    # Higher is worse. Severity dominates; reversibility breaks ties.
    private def self.rank(s : RiskSummary) : Int32
      severity_rank(s.severity) * 10 + reversible_rank(s.reversible)
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
