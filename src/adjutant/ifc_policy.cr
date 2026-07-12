require "json"
require "./risk_profile"

module Adjutant
  # How a matched sink rule resolves a risky call.
  #
  # Allow: proceed, no interruption.
  # Ask: pause and surface the concrete flow to the agent/user for a
  #   live decision — requires an actual prompting mechanism, added in
  #   piece 4 (enforcement); not wired up yet.
  # Reject: policy has already decided no, unconditionally — no prompt.
  #   For organizational rules that should never be silently approved
  #   regardless of who's asked, and for unattended execution where
  #   there's no one to ask.
  #
  # See research/IFC_DESIGN.md's "Sink policy (piece 3)" section.
  enum SinkAction
    Allow
    Ask
    Reject
  end

  # How SensitivityPattern#pattern is interpreted.
  enum PatternType
    Exact
    Regex
  end

  # A single origin → sensitivity rule. Matched against a ProvenanceTag's
  # (kind, origin) at tag-creation time (e.g. a File IO module checking
  # the path it just opened). Specificity is stated explicitly via
  # `priority` — not inferred from pattern syntax or array position; see
  # the design doc for why (hostnames get more specific reading left,
  # paths reading right, so no single syntax-driven rule generalizes).
  struct SensitivityPattern
    include JSON::Serializable

    getter kind : ProvenanceKind
    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String
    getter priority : Int32
    getter sensitivity : Sensitivity

    def initialize(@kind : ProvenanceKind, @pattern : String, @priority : Int32,
                   @sensitivity : Sensitivity, @pattern_type : PatternType = PatternType::Exact)
    end

    def matches?(origin : String) : Bool
      case pattern_type
      in .exact? then pattern == origin
      in .regex? then Regex.new(pattern).matches?(origin)
      end
    end
  end

  # A single (RiskTag, Sensitivity) → SinkAction rule, consulted at the
  # sink check. Sensitivity::None always allows regardless of table
  # contents (see IFCPolicy#action_for) — rows here only need to cover
  # Elevated/High cases that should escalate above the default.
  struct SinkRule
    include JSON::Serializable

    getter tag : RiskTag
    getter sensitivity : Sensitivity
    getter action : SinkAction

    def initialize(@tag : RiskTag, @sensitivity : Sensitivity, @action : SinkAction)
    end
  end

  # Raised when two SensitivityPattern rules match the same (kind,
  # origin) at the same top priority — ambiguous policy, not resolved
  # silently. See research/IFC_DESIGN.md's "Pattern matching for
  # sensitivity lookup" section for why this is a hard error rather than
  # picking one arbitrarily: with explicit priorities, a tie means the
  # policy author's priorities actually collide, not that Adjutant
  # failed to compute specificity.
  class AmbiguousPolicyError < Exception
  end

  # A single IFC policy: sensitivity lookup rules plus sink action
  # rules. Loaded and owned by whatever embeds Adjutant (the agent) —
  # Adjutant itself never reads a policy path off disk; the agent parses
  # or constructs an IFCPolicy and passes it to Interpreter. See
  # research/IFC_DESIGN.md's "Policy object" and "Sink policy" sections.
  class IFCPolicy
    include JSON::Serializable

    getter sensitivity_patterns : Array(SensitivityPattern)
    getter sink_rules : Array(SinkRule)

    def initialize(@sensitivity_patterns : Array(SensitivityPattern) = [] of SensitivityPattern,
                   @sink_rules : Array(SinkRule) = [] of SinkRule)
    end

    # origin → sensitivity lookup, consulted by native modules at
    # tag-creation time. Highest-priority match wins; a tie among
    # matches at the top priority raises AmbiguousPolicyError. No match
    # at all → Sensitivity::None.
    def sensitivity_for(kind : ProvenanceKind, origin : String) : Sensitivity
      matches = sensitivity_patterns.select { |pattern| pattern.kind == kind && pattern.matches?(origin) }
      return Sensitivity::None if matches.empty?

      top_priority = matches.max_of(&.priority)
      top = matches.select { |pattern| pattern.priority == top_priority }
      if top.size > 1
        raise AmbiguousPolicyError.new(
          "ambiguous IFC policy: #{top.size} sensitivity_patterns rules tie at priority " \
          "#{top_priority} for #{kind}:#{origin}"
        )
      end
      top.first.sensitivity
    end

    # (RiskTag, Sensitivity) → action lookup, consulted at the sink
    # check. Sensitivity::None always allows regardless of table
    # contents — the universal default is not overridable by a rule,
    # only sensitivities above None can be. No matching rule for a
    # non-None sensitivity → Allow (a tag with no configured rows is
    # treated as not policy-relevant, not as an implicit escalation).
    def action_for(tag : RiskTag, sensitivity : Sensitivity) : SinkAction
      return SinkAction::Allow if sensitivity.none?
      sink_rules.find { |rule| rule.tag == tag && rule.sensitivity == sensitivity }
        .try(&.action) || SinkAction::Allow
    end
  end
end
