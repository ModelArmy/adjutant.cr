require "json"
require "./authority"
require "./risk_profile"
require "./diagnostic"
require "./risk_flow_label"
require "./real_path"

module Adjutant
  # What a matched risk-flow rule does with a call:
  #
  #   Allow:  the call proceeds.
  #   Ask:    the host's `on_risk_flow_decision` callback decides.
  #   Reject: the call is refused without asking.
  #
  # See research/IFC_DESIGN.md, "Risk flow policy".
  enum RiskFlowAction
    Allow
    Ask
    Reject
  end

  # How a policy pattern is matched: `SensitivityPattern`'s, and a
  # risk-flow exception's origin and subject.
  enum PatternType
    Exact
    Regex

    # Whether `value` matches `pattern` read as this type.
    def matches?(pattern : String, value : String) : Bool
      case self
      in .exact? then pattern == value
      in .regex? then ::Regex.new(pattern).matches?(value)
      end
    end

    # The form an exact path pattern is matched in: `RealPath.of`,
    # since a File subject is judged as its real path
    # (`Broker#authorize`). A regex can't be resolved, so it is
    # matched as written, against real paths.
    def path_pattern(pattern : String) : String
      return pattern if regex?
      RealPath.of(pattern) || pattern
    end
  end

  # One rule assigning a sensitivity to subjects of a kind whose
  # origin matches `pattern`, consulted when data is tagged.
  # Specificity is stated by `priority`, never inferred from the
  # pattern or its position: hosts get more specific leftwards, paths
  # rightwards.
  struct SensitivityPattern
    include JSON::Serializable

    getter kind : ProvenanceKind
    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String
    getter priority : Int32
    getter sensitivity : Sensitivity

    # `pattern` as matched; see `matched_pattern`.
    @[JSON::Field(ignore: true)]
    @matched : String = ""

    def initialize(@kind : ProvenanceKind, @pattern : String, @priority : Int32,
                   @sensitivity : Sensitivity, @pattern_type : PatternType = PatternType::Exact)
      @matched = matched_pattern
    end

    protected def after_initialize
      @matched = matched_pattern
    end

    def matches?(origin : String) : Bool
      pattern_type.matches?(@matched, origin)
    end

    # A File pattern's path form (`PatternType#path_pattern`), resolved
    # when the policy is built; any other kind's pattern as written.
    private def matched_pattern : String
      kind.file? ? pattern_type.path_pattern(pattern) : pattern
    end
  end

  # Where data must come from for a risk-flow exception to apply: an
  # origin of `kind` matching `pattern`, such as the environment
  # variable `STRIPE_KEY`.
  struct RiskFlowOrigin
    include JSON::Serializable

    getter kind : ProvenanceKind
    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String

    # `pattern` as matched; see `matched_pattern`.
    @[JSON::Field(ignore: true)]
    @matched : String = ""

    def initialize(@kind : ProvenanceKind, @pattern : String, @pattern_type : PatternType = PatternType::Exact)
      @matched = matched_pattern
    end

    protected def after_initialize
      @matched = matched_pattern
    end

    def matches?(tag : ProvenanceTag) : Bool
      tag.kind == kind && pattern_type.matches?(@matched, tag.origin)
    end

    # A File origin's path form (`PatternType#path_pattern`), resolved
    # when the policy is built; any other kind's pattern as written.
    private def matched_pattern : String
      kind.file? ? pattern_type.path_pattern(pattern) : pattern
    end
  end

  # Where data must be going for a risk-flow exception to apply: the
  # subject a call exercises its authority on, as `Broker#authorize`
  # names it, such as `https://api.stripe.com:443` or a path.
  struct RiskFlowSubject
    include JSON::Serializable

    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String

    # `pattern` as matched; see `matched_pattern`.
    @[JSON::Field(ignore: true)]
    @matched : String = ""

    def initialize(@pattern : String, @pattern_type : PatternType = PatternType::Exact)
      @matched = matched_pattern
    end

    protected def after_initialize
      @matched = matched_pattern
    end

    # False for an unknown subject: an exception naming where data
    # goes never applies where that can't be told.
    def matches?(subject : String?) : Bool
      return false unless subject
      pattern_type.matches?(@matched, subject)
    end

    # A subject has no kind, so an exact pattern that is an absolute
    # path is taken for a file and put in its path form
    # (`PatternType#path_pattern`) when the policy is built; a host
    # such as `https://api.stripe.com:443` is not absolute.
    private def matched_pattern : String
      ::Path.new(pattern).absolute? ? pattern_type.path_pattern(pattern) : pattern
    end
  end

  # One rule mapping data of `sensitivity` reaching a sink with
  # `authority` to an action. `Sensitivity::None` always allows, so
  # rules only cover Elevated and High. Keyed on Authority, not
  # Effect: the question is what the call may do.
  #
  # A rule with neither `origin` nor `subject` is a base rule: one per
  # pair, covering it. A rule with either is an exception, which
  # overrides its pair's base rule for data from `origin` reaching
  # `subject`, and needs a `priority` to rank it against other
  # exceptions; it never covers a pair.
  #
  #   RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
  #     origin: RiskFlowOrigin.new(ProvenanceKind::Env, "STRIPE_KEY"),
  #     subject: RiskFlowSubject.new("https://api.stripe.com:443"), priority: 10)
  struct RiskFlowRule
    include JSON::Serializable

    getter authority : Authority
    getter sensitivity : Sensitivity
    getter action : RiskFlowAction
    getter origin : RiskFlowOrigin? = nil
    getter subject : RiskFlowSubject? = nil
    getter priority : Int32? = nil

    def initialize(@authority : Authority, @sensitivity : Sensitivity, @action : RiskFlowAction,
                   @origin : RiskFlowOrigin? = nil, @subject : RiskFlowSubject? = nil,
                   @priority : Int32? = nil)
    end

    def exception? : Bool
      !origin.nil? || !subject.nil?
    end

    # Whether this rule governs `tag` reaching `subject` under
    # `authority`. Every pattern given must match.
    def applies?(authority : Authority, tag : ProvenanceTag, subject : String?) : Bool
      return false unless authority == @authority && tag.sensitivity == sensitivity
      @origin.try { |origin| return false unless origin.matches?(tag) }
      @subject.try { |pattern| return false unless pattern.matches?(subject) }
      true
    end

    def to_s(io : IO) : Nil
      io << authority << '/' << sensitivity
      @origin.try { |origin| io << " from " << origin.kind.to_s.downcase << ':' << origin.pattern }
      @subject.try { |pattern| io << " to " << pattern.pattern }
    end
  end

  # Raised when two sensitivity patterns match the same subject at the
  # same top priority: the policy's priorities collide, and picking
  # one would hide that. A Crystal exception, not script-visible: a
  # broken policy is the host's configuration error, and a script must
  # not be able to rescue past it.
  class AmbiguousRiskFlowPolicyError < Exception
    getter diagnostic : Diagnostic?

    def initialize(diagnostic : Diagnostic)
      @diagnostic = diagnostic
      super(diagnostic.to_line)
    end

    def initialize(message : String)
      @diagnostic = nil
      super(message)
    end
  end

  # Raised when a policy is built without an action for some pair of
  # authority and sensitivity, or with `default: Allow`. A Crystal
  # exception, not script-visible: an incomplete policy is the host's
  # configuration error, reported when the policy is built rather than
  # when an unattended run first reaches the gap.
  class InvalidRiskFlowPolicyError < Exception
  end

  # A risk-flow policy: sensitivity patterns and action rules. The
  # host builds it and passes it to the Interpreter; Adjutant never
  # reads one from disk. Every pair of `Authority` and a sensitivity
  # above None has an action, from a rule or from `default_action`,
  # which may be Ask or Reject but not Allow. A gap, including one an
  # `Authority` added later opens, therefore never lets data through.
  # A host that wants no assessment passes `RiskFlowPolicy.reject_all`.
  #
  #   RiskFlowPolicy.new(
  #     risk_flow_rules: [RiskFlowRule.new(Authority::Read, Sensitivity::High, RiskFlowAction::Allow)],
  #     default_action: RiskFlowAction::Ask,
  #   )
  #
  # In JSON the default is `"default"`, such as `"default": "ask"`.
  class RiskFlowPolicy
    include JSON::Serializable

    getter sensitivity_patterns : Array(SensitivityPattern)
    getter risk_flow_rules : Array(RiskFlowRule)

    # Rejects every non-None sensitivity whatever the rules say; see
    # `.reject_all`. Never loaded from JSON.
    @[JSON::Field(ignore: true)]
    getter? reject_all_flows : Bool = false

    # The action for a pair no rule names: Ask, Reject, or nil when
    # the rules name every pair.
    @[JSON::Field(key: "default")]
    getter default_action : RiskFlowAction? = nil

    def initialize(@sensitivity_patterns : Array(SensitivityPattern) = [] of SensitivityPattern,
                   @risk_flow_rules : Array(RiskFlowRule) = [] of RiskFlowRule,
                   @reject_all_flows : Bool = false,
                   @default_action : RiskFlowAction? = nil)
      validate!
    end

    # Called by `JSON::Serializable` after `from_json`, which doesn't
    # run `initialize`.
    protected def after_initialize
      validate!
    end

    # Every pair of authority and sensitivity a rule must cover when
    # there is no default.
    def self.required_pairs : Array({Authority, Sensitivity})
      Authority.values.flat_map do |authority|
        [Sensitivity::Elevated, Sensitivity::High].map { |sensitivity| {authority, sensitivity} }
      end
    end

    # Raises InvalidRiskFlowPolicyError for `default: Allow`, for an
    # exception without a priority or a base rule with one, for two
    # base rules on one pair, or for pairs neither a base rule nor a
    # default covers, naming every one.
    private def validate! : Nil
      return if @reject_all_flows
      if @default_action.try(&.allow?)
        raise InvalidRiskFlowPolicyError.new(
          "a risk-flow policy's default may be Ask or Reject, not Allow; write an Allow rule for each pair that should allow")
      end
      validate_rules!
      return if @default_action

      covered = base_rules.map { |rule| {rule.authority, rule.sensitivity} }.to_set
      missing = RiskFlowPolicy.required_pairs.reject { |pair| covered.includes?(pair) }
      return if missing.empty?
      names = missing.map { |authority, sensitivity| "#{authority}/#{sensitivity}" }
      raise InvalidRiskFlowPolicyError.new(
        "a risk-flow policy needs a rule for each of #{names.join(", ")}, or a default (Ask or Reject)")
    end

    private def validate_rules! : Nil
      @risk_flow_rules.each do |rule|
        if rule.exception? && rule.priority.nil?
          raise InvalidRiskFlowPolicyError.new(
            "the risk-flow exception #{rule} needs a priority, to rank it against other exceptions")
        end
        if !rule.exception? && rule.priority
          raise InvalidRiskFlowPolicyError.new(
            "the risk-flow rule #{rule} has a priority but no origin or subject; only exceptions take one")
        end
      end

      by_pair = base_rules.group_by { |rule| {rule.authority, rule.sensitivity} }
      duplicates = by_pair.select { |_, rules| rules.size > 1 }
      return if duplicates.empty?
      names = duplicates.keys.map { |authority, sensitivity| "#{authority}/#{sensitivity}" }
      raise InvalidRiskFlowPolicyError.new(
        "a risk-flow policy has more than one rule without an origin or subject for #{names.join(", ")}; " \
        "give the narrower one an origin or subject and a priority")
    end

    private def base_rules : Array(RiskFlowRule)
      @risk_flow_rules.reject(&.exception?)
    end

    # A policy that rejects every flow of sensitive data, including
    # through authorities added later.
    def self.reject_all : RiskFlowPolicy
      new(reject_all_flows: true)
    end

    # The sensitivity of `origin`: the highest-priority matching
    # pattern's, or None if nothing matches. Raises
    # AmbiguousRiskFlowPolicyError on a tie at the top priority.
    def sensitivity_for(kind : ProvenanceKind, origin : String) : Sensitivity
      matches = sensitivity_patterns.select { |pattern| pattern.kind == kind && pattern.matches?(origin) }
      return Sensitivity::None if matches.empty?

      top_priority = matches.max_of(&.priority)
      top = matches.select { |pattern| pattern.priority == top_priority }
      if top.size > 1
        raise AmbiguousRiskFlowPolicyError.new(
          Diagnostic.new(
            code: "H003",
            data: {
              "count"    => top.size.to_s,
              "priority" => top_priority.to_s,
              "target"   => "#{kind}:#{origin}",
            }
          )
        )
      end
      top.first.sensitivity
    end

    # The action for `sensitivity` reaching a sink with `authority`
    # from no particular origin to no particular subject, with the
    # rule that decided it (nil for a default):
    #
    #   1. None sensitivity: Allow, always.
    #   2. `reject_all_flows`: Reject.
    #   3. The pair's base rule: its action.
    #   4. Otherwise the default, or Reject.
    def action_for(authority : Authority, sensitivity : Sensitivity) : {RiskFlowAction, RiskFlowRule?}
      return {RiskFlowAction::Allow, nil} if sensitivity.none?
      return {RiskFlowAction::Reject, nil} if reject_all_flows?
      matched = base_rules.find { |rule| rule.authority == authority && rule.sensitivity == sensitivity }
      # A valid policy covers every pair, so the last fallback is
      # unreachable; it fails closed all the same.
      {matched.try(&.action) || @default_action || RiskFlowAction::Reject, matched}
    end

    # The action for `tag`'s data reaching `subject` (nil when unknown)
    # with `authority`: the highest-priority exception that applies,
    # or else the base action as above. Raises
    # AmbiguousRiskFlowPolicyError when exceptions tie at the top
    # priority.
    def action_for(authority : Authority, tag : ProvenanceTag, subject : String?) : {RiskFlowAction, RiskFlowRule?}
      return {RiskFlowAction::Allow, nil} if tag.sensitivity.none?
      return {RiskFlowAction::Reject, nil} if reject_all_flows?

      exceptions = risk_flow_rules.select { |rule| rule.exception? && rule.applies?(authority, tag, subject) }
      return action_for(authority, tag.sensitivity) if exceptions.empty?

      top_priority = exceptions.max_of { |rule| rule.priority || 0 }
      top = exceptions.select { |rule| rule.priority == top_priority }
      if top.size > 1
        raise AmbiguousRiskFlowPolicyError.new(
          Diagnostic.new(
            code: "H003",
            data: {
              "count"    => top.size.to_s,
              "priority" => top_priority.to_s,
              "target"   => "#{authority} data from #{tag} to #{subject || "an unknown subject"}",
            }
          )
        )
      end
      {top.first.action, top.first}
    end
  end
end
