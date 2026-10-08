require "json"
require "./authority"
require "./risk_profile"
require "./diagnostic"
require "./risk_flow_label"
require "./real_path"
require "./host_name"

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

    # `pattern`, read as this type, compiled for matching: its regex,
    # or nil for an exact pattern, which is compared as a string.
    # Raises InvalidRiskFlowPolicyError, naming the pattern, for a regex
    # that doesn't compile.
    def compile(pattern : String) : ::Regex?
      return unless regex?
      ::Regex.new(pattern)
    rescue ex : ArgumentError
      raise InvalidRiskFlowPolicyError.new("invalid regex #{pattern.inspect} in a risk-flow policy: #{ex.message}")
    end

    # Whether `value` matches a pattern `compile` has prepared: `regex`
    # when there is one, else the exact `pattern`.
    def self.matches?(regex : ::Regex?, pattern : String, value : String) : Bool
      regex ? regex.matches?(value) : pattern == value
    end

    # The form an exact path pattern is matched in: `RealPath.of`,
    # since a File subject is judged as its real path
    # (`Broker#authorize`). A regex can't be resolved, so it is
    # matched as written, against real paths.
    def path_pattern(pattern : String) : String
      return pattern if regex?
      RealPath.of(pattern) || pattern
    end

    # The form an exact host pattern is matched in: `HostName.fold`,
    # as a Host subject is judged. A regex is matched as written,
    # against folded hosts.
    def host_pattern(pattern : String) : String
      regex? ? pattern : HostName.fold(pattern)
    end
  end

  # One rule assigning a sensitivity to subjects of a kind whose
  # origin matches `pattern`, consulted when data is tagged.
  # Specificity is stated by `priority`, never inferred from the
  # pattern or its position: hosts get more specific leftwards, paths
  # rightwards.
  struct SensitivityPattern
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter kind : ProvenanceKind
    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String
    getter priority : Int32
    getter sensitivity : Sensitivity

    # `pattern` as matched; see `matched_pattern`.
    @[JSON::Field(ignore: true)]
    protected getter matched : String = ""

    # `matched` compiled, when it is a regex (`PatternType#compile`).
    @[JSON::Field(ignore: true)]
    @regex : ::Regex? = nil

    def initialize(@kind : ProvenanceKind, @pattern : String, @priority : Int32,
                   @sensitivity : Sensitivity, @pattern_type : PatternType = PatternType::Exact)
      settle
    end

    protected def after_initialize
      settle
    end

    def matches?(origin : String) : Bool
      PatternType.matches?(@regex, @matched, origin)
    end

    # Whether this and `other` say the same thing: one kind, type,
    # priority and pattern, as matched.
    def same_match?(other : SensitivityPattern) : Bool
      {kind, pattern_type, priority, matched} == {other.kind, other.pattern_type, other.priority, other.matched}
    end

    # Whether this pattern matches the origin `exact`, an exact
    # pattern, names.
    def covers?(exact : SensitivityPattern) : Bool
      kind == exact.kind && PatternType.matches?(@regex, @matched, exact.matched)
    end

    # The exact one of this and `other` when both match the origin it
    # names, else nil.
    def common_exact(other : SensitivityPattern) : SensitivityPattern?
      return self if pattern_type.exact? && other.covers?(self)
      other if other.pattern_type.exact? && covers?(other)
    end

    def to_s(io : IO) : Nil
      io << kind.to_s.downcase << ':' << pattern
      io << " (regex)" if pattern_type.regex?
    end

    # Prepares the pattern for matching, once, when built:
    # `matched_pattern`, then compiled (`PatternType#compile`).
    private def settle : Nil
      @matched = matched_pattern
      @regex = pattern_type.compile(@matched)
    end

    # A File pattern's path form (`PatternType#path_pattern`) or a
    # Host pattern's folded form (`PatternType#host_pattern`), settled
    # when the policy is built; any other kind's pattern as written.
    private def matched_pattern : String
      case kind
      when .file? then pattern_type.path_pattern(pattern)
      when .host? then pattern_type.host_pattern(pattern)
      else             pattern
      end
    end
  end

  # Where data must come from for a risk-flow exception to apply: an
  # origin of `kind` matching `pattern`, such as the environment
  # variable `STRIPE_KEY`.
  struct RiskFlowOrigin
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter kind : ProvenanceKind
    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String

    # `pattern` as matched; see `matched_pattern`.
    @[JSON::Field(ignore: true)]
    protected getter matched : String = ""

    # `matched` compiled, when it is a regex (`PatternType#compile`).
    @[JSON::Field(ignore: true)]
    @regex : ::Regex? = nil

    def initialize(@kind : ProvenanceKind, @pattern : String, @pattern_type : PatternType = PatternType::Exact)
      settle
    end

    protected def after_initialize
      settle
    end

    def matches?(tag : ProvenanceTag) : Bool
      tag.kind == kind && PatternType.matches?(@regex, @matched, tag.origin)
    end

    # Whether this and `other` name the same origins: one kind, type
    # and pattern, as matched.
    def same_match?(other : RiskFlowOrigin) : Bool
      {kind, pattern_type, matched} == {other.kind, other.pattern_type, other.matched}
    end

    # Whether this pattern matches the origin `exact`, an exact
    # pattern, names.
    def covers?(exact : RiskFlowOrigin) : Bool
      kind == exact.kind && PatternType.matches?(@regex, @matched, exact.matched)
    end

    # Prepares the pattern for matching, once, when built:
    # `matched_pattern`, then compiled (`PatternType#compile`).
    private def settle : Nil
      @matched = matched_pattern
      @regex = pattern_type.compile(@matched)
    end

    # A File origin's path form (`PatternType#path_pattern`) or a Host
    # origin's folded form (`PatternType#host_pattern`), settled when
    # the policy is built; any other kind's pattern as written.
    private def matched_pattern : String
      case kind
      when .file? then pattern_type.path_pattern(pattern)
      when .host? then pattern_type.host_pattern(pattern)
      else             pattern
      end
    end
  end

  # Where data must be going for a risk-flow exception to apply: the
  # subject a call exercises its authority on, as `Broker#authorize`
  # names it, such as `https://api.stripe.com:443` or a path.
  struct RiskFlowSubject
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter pattern_type : PatternType = PatternType::Exact
    getter pattern : String

    # `pattern` as matched; see `matched_pattern`.
    @[JSON::Field(ignore: true)]
    protected getter matched : String = ""

    # `matched` compiled, when it is a regex (`PatternType#compile`).
    @[JSON::Field(ignore: true)]
    @regex : ::Regex? = nil

    def initialize(@pattern : String, @pattern_type : PatternType = PatternType::Exact)
      settle
    end

    protected def after_initialize
      settle
    end

    # False for an unknown subject: an exception naming where data
    # goes never applies where that can't be told.
    def matches?(subject : String?) : Bool
      return false unless subject
      PatternType.matches?(@regex, @matched, subject)
    end

    # Whether this and `other` name the same subjects: one type and
    # pattern, as matched.
    def same_match?(other : RiskFlowSubject) : Bool
      {pattern_type, matched} == {other.pattern_type, other.matched}
    end

    # Whether this pattern matches the subject `exact`, an exact
    # pattern, names.
    def covers?(exact : RiskFlowSubject) : Bool
      PatternType.matches?(@regex, @matched, exact.matched)
    end

    # Prepares the pattern for matching, once, when built:
    # `matched_pattern`, then compiled (`PatternType#compile`).
    private def settle : Nil
      @matched = matched_pattern
      @regex = pattern_type.compile(@matched)
    end

    # A subject has no kind, so its form decides when the policy is
    # built: an absolute path is taken for a file
    # (`PatternType#path_pattern`), a URL such as
    # `https://api.stripe.com:443` for a host
    # (`PatternType#host_pattern`), and anything else, such as an
    # environment variable's name, is matched as written.
    private def matched_pattern : String
      if ::Path.new(pattern).absolute?
        pattern_type.path_pattern(pattern)
      elsif pattern.includes?("://")
        pattern_type.host_pattern(pattern)
      else
        pattern
      end
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
    include JSON::Serializable::Strict

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

    # Whether this exception and `other` govern the same flows: one
    # pair and priority, and the same origin and subject patterns.
    def same_scope?(other : RiskFlowRule) : Bool
      return false unless same_rank?(other)
      same_side?(origin, other.origin) && same_side?(subject, other.subject)
    end

    # Whether this exception and `other` certainly both apply to some
    # flow: one pair and priority, and on each side either no pattern
    # on both or an exact one the other side matches or leaves open
    # (`common_origin`, `common_subject`).
    def certainly_overlaps?(other : RiskFlowRule) : Bool
      return false unless same_rank?(other)
      side_certain?(origin, other.origin) && side_certain?(subject, other.subject)
    end

    # The exact origin pattern whose value this exception and `other`
    # both match, if there is one.
    def common_origin(other : RiskFlowRule) : RiskFlowOrigin?
      side_exact(origin, other.origin)
    end

    # The exact subject pattern whose value this exception and `other`
    # both match, if there is one.
    def common_subject(other : RiskFlowRule) : RiskFlowSubject?
      side_exact(subject, other.subject)
    end

    # Whether this rule may apply to data from the value `origin` names
    # reaching the value `subject` names, nil meaning any value. Errs
    # towards yes where a pattern meets an unknown value.
    def may_apply_to?(origin : RiskFlowOrigin?, subject : RiskFlowSubject?) : Bool
      side_may_cover?(@origin, origin) && side_may_cover?(@subject, subject)
    end

    def to_s(io : IO) : Nil
      io << authority << '/' << sensitivity
      @origin.try { |origin| io << " from " << origin.kind.to_s.downcase << ':' << origin.pattern }
      @subject.try { |pattern| io << " to " << pattern.pattern }
    end

    private def same_rank?(other : RiskFlowRule) : Bool
      {authority, sensitivity, priority} == {other.authority, other.sensitivity, other.priority}
    end

    private def same_side?(pattern : T?, other : T?) : Bool forall T
      return pattern.nil? && other.nil? unless pattern && other
      pattern.same_match?(other)
    end

    private def side_certain?(pattern : T?, other : T?) : Bool forall T
      return true unless pattern || other
      !side_exact(pattern, other).nil?
    end

    # The exact pattern on one side whose value both sides match: one
    # the other matches, or one the other leaves open.
    private def side_exact(pattern : T?, other : T?) : T? forall T
      if pattern && other
        return pattern if pattern.pattern_type.exact? && other.covers?(pattern)
        return other if other.pattern_type.exact? && pattern.covers?(other)
        return
      end
      named = pattern || other
      named if named && named.pattern_type.exact?
    end

    private def side_may_cover?(pattern : T?, exact : T?) : Bool forall T
      return true unless pattern && exact
      pattern.covers?(exact)
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
  # In JSON the default is `"default"`, such as `"default": "ask"`. An
  # unknown key at any level raises `JSON::SerializableError`, since a
  # misspelled key that narrows a rule would otherwise widen it.
  class RiskFlowPolicy
    include JSON::Serializable
    include JSON::Serializable::Strict

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
      validate_pattern_ties!
      validate_exception_ties!
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

    # Raises InvalidRiskFlowPolicyError for two sensitivity patterns
    # certain to tie (H003) on some origin: the same match at one
    # priority, or an exact pattern another matches at its priority
    # with no higher pattern deciding its origin. A tie only a real
    # origin reveals, such as between two different regexes, is left
    # to `sensitivity_for`.
    private def validate_pattern_ties! : Nil
      @sensitivity_patterns.each_combination(2, reuse: false) do |pair|
        first, second = pair
        next unless first.priority == second.priority && certain_pattern_tie?(first, second)
        raise InvalidRiskFlowPolicyError.new(
          "the sensitivity patterns #{first} and #{second} would tie at priority #{first.priority} (H003); " \
          "give the intended one a higher priority, or remove one")
      end
    end

    private def certain_pattern_tie?(first : SensitivityPattern, second : SensitivityPattern) : Bool
      return true if first.same_match?(second)
      witness = first.common_exact(second)
      return false unless witness
      @sensitivity_patterns.none? { |pattern| pattern.priority > witness.priority && pattern.covers?(witness) }
    end

    # Raises InvalidRiskFlowPolicyError for two exceptions certain to
    # tie (H003) on some flow: the same scope at one priority, or a
    # flow both certainly govern at their priority that no higher
    # exception may decide. A tie only a real flow reveals is left to
    # `action_for`.
    private def validate_exception_ties! : Nil
      exceptions = @risk_flow_rules.select(&.exception?)
      exceptions.each_combination(2, reuse: false) do |pair|
        first, second = pair
        next unless certain_exception_tie?(first, second, exceptions)
        raise InvalidRiskFlowPolicyError.new(
          "the risk-flow exceptions #{first} and #{second} would tie at priority #{first.priority} (H003); " \
          "give the intended one a higher priority, or remove one")
      end
    end

    private def certain_exception_tie?(first : RiskFlowRule, second : RiskFlowRule, exceptions : Array(RiskFlowRule)) : Bool
      return true if first.same_scope?(second)
      return false unless first.certainly_overlaps?(second)
      origin = first.common_origin(second)
      subject = first.common_subject(second)
      exceptions.none? do |rule|
        rule.authority == first.authority && rule.sensitivity == first.sensitivity &&
          (rule.priority || 0) > (first.priority || 0) && rule.may_apply_to?(origin, subject)
      end
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
