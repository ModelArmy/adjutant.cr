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

  # Walks a RiskNode tree and produces the single worst-case
  # RiskSummary — the path an attacker or a careless script would
  # actually hit, not a flattened union across mutually-exclusive
  # branches.
  #
  # Ordering used to pick "worse": Severity::Error > Warning > Info;
  # ties broken by Reversibility::No > Depends > Yes. RiskUnresolved
  # always outranks everything (see risk_node.cr for why).
  module RiskAggregator
    def self.summarize(node : RiskNode) : RiskSummary
      case node
      when RiskLeaf
        RiskSummary.new(node.profile.tags, node.profile.reversible, node.profile.severity,
          [node.description], false)
      when RiskUnresolved
        RiskSummary.new(Set{RiskTag::ExecutesCode}, Reversibility::No, Severity::Error,
          ["unresolved call: #{node.description}"], false)
      when RiskSequence
        summarize_sequence(node)
      when RiskChoice
        summarize_choice(node)
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
