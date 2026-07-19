require "./risk_node"
require "./risk_profile"

module Adjutant
  # A single worst-case path through a RiskNode tree, kept as a trail
  # of descriptions so presentation can say *why* — e.g. "delete_file
  # (inside if branch: user_confirmed == false)" — rather than just a
  # severity badge.
  struct RiskSummary
    getter tags : Set(RiskTag)
    getter reversible : Reversibility
    getter severity : Severity
    getter path : Array(String) # trail of descriptions/origins, root to leaf
    getter? iterated : Bool     # true if any Sequence on the worst path was iterated

    def initialize(@tags, @reversible, @severity, @path, @iterated)
    end

    def self.none : RiskSummary
      RiskSummary.new(Set(RiskTag).new, Reversibility::Yes, Severity::Info, [] of String, false)
    end
  end

  # One resolved (or unresolved) leaf found anywhere in a RiskNode
  # tree, with enough context for a UX to group, filter, or sort —
  # unlike RiskSummary, which collapses everything to one worst-case
  # path. `iterated`/`branch_path` say WHERE in the control-flow shape
  # this leaf sits, since two leaves with identical tags can carry very
  # different weight (once, vs. inside a loop; unconditional, vs. only
  # on the `--force` branch).
  struct RiskFinding
    getter description : String
    getter profile : RiskProfile
    getter line : Int32
    getter? iterated : Bool
    getter branch_path : Array(String) # e.g. ["if branch", "case branch"]

    def initialize(@description, @profile, @line, @iterated, @branch_path)
    end
  end

  # Walks a RiskNode tree, either into every individual finding
  # (all_findings) or the single worst-case RiskSummary (summarize) —
  # the path an attacker or a careless script would actually hit, not
  # a flattened union across mutually-exclusive branches.
  #
  # Ordering used to pick "worse": Severity::Error > Warning > Info;
  # ties broken by Reversibility::No > Depends > Yes. RiskUnresolved
  # always outranks everything (see risk_node.cr for why).
  module RiskAggregator
    # Every RiskLeaf/RiskUnresolved anywhere in the tree — not just the
    # worst-case path summarize() returns. A UX can group these by
    # description (dedup repeated calls to the same function), filter
    # by severity, or sort by reversibility itself; RiskAggregator
    # takes no view on presentation.
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
        # Included at full severity, same philosophy as RiskUnresolved
        # outranking everything else (see class docs above) — this
        # project consistently treats "can't confirm" as a reason to
        # surface loudly, not a reason to under-report. Tagged via
        # branch_path so presentation can distinguish "this WILL
        # happen" from "this MIGHT happen, handed off to a callee we
        # can't see into" without losing the underlying finding.
        all_findings(node.child, iterated, branch_path + ["deferred: #{node.reason}"])
      else
        [] of RiskFinding
      end
    end

    # The RiskProfile equivalent RiskUnresolved is treated as in
    # summarize() — kept as one place so both entry points agree on
    # what "unresolved" means as a profile.
    private def self.unresolved_profile : RiskProfile
      RiskProfile.new(tags: Set{RiskTag::ExecutesCode}, reversible: Reversibility::No, severity: Severity::Error)
    end

    def self.summarize(node : RiskNode) : RiskSummary
      case node
      when RiskLeaf
        RiskSummary.new(node.profile.tags, node.profile.reversible, node.profile.severity,
          [node.description], false)
      when RiskUnresolved
        p = unresolved_profile
        RiskSummary.new(p.tags, p.reversible, p.severity,
          ["unresolved call: #{node.description}"], false)
      when RiskSequence
        summarize_sequence(node)
      when RiskChoice
        summarize_choice(node)
      when RiskDeferred
        summarize_deferred(node)
      else
        raise "unreachable RiskNode subtype"
      end
    end

    # All children occur — union tags, OR-ed reversible/severity via
    # worse-wins, path is the concatenation of each child's worst path.
    private def self.summarize_sequence(node : RiskSequence) : RiskSummary
      return RiskSummary.none if node.children.empty?
      child_summaries = node.children.map { |child| summarize(child) }
      tags = Set(RiskTag).new
      child_summaries.each { |summary| tags.concat(summary.tags) }
      worst = child_summaries.max_by { |summary| rank(summary) }
      RiskSummary.new(
        tags,
        worst.reversible,
        worst.severity,
        child_summaries.flat_map(&.path),
        node.iterated? || child_summaries.any?(&.iterated?),
      )
    end

    # Exactly one child occurs — report the single worst-case branch,
    # tagged with which branch it was, rather than unioning mutually
    # exclusive outcomes together.
    private def self.summarize_choice(node : RiskChoice) : RiskSummary
      return RiskSummary.none if node.children.empty?
      child_summaries = node.children.map { |child| summarize(child) }
      worst = child_summaries.max_by { |summary| rank(summary) }
      RiskSummary.new(
        worst.tags,
        worst.reversible,
        worst.severity,
        ["#{node.origin} branch"] + worst.path,
        worst.iterated?,
      )
    end

    # The child's full severity/reversibility/tags are used as-is (see
    # all_findings' RiskDeferred case for why: this project treats
    # "can't confirm" as a reason to surface loudly, matching how
    # RiskUnresolved is handled, not a reason to under-report) — only
    # the path gets a "deferred: <reason>" prefix, so presentation can
    # tell a human this risk is contingent on a callee actually
    # invoking what was handed to it, not something that will
    # definitely run the way an ordinary RiskSequence child does.
    private def self.summarize_deferred(node : RiskDeferred) : RiskSummary
      child_summary = summarize(node.child)
      RiskSummary.new(
        child_summary.tags,
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
