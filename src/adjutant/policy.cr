require "yaml"
require "./policy_yaml"
require "./policy_section"
require "./risk_flow_policy"
require "./legate/policy_section"

module Adjutant
  # The policy a script runs under (POLICY.md): what it may touch and
  # consume, as Legate's grants and limits, and where sensitive data
  # may go, as a risk-flow policy.
  class Policy
    TOP_KEYS = {"grants", "limits", "risk_flow"}

    getter risk_flow : RiskFlowPolicy
    getter grants : Legate::Grants

    def initialize(@risk_flow : RiskFlowPolicy, @grants : Legate::Grants = Legate::Grants.deny_all)
    end

    # Core's section and Legate's.
    def self.default_sections : Array(PolicySection)
      [CorePolicySection.new, Legate::PolicySection.new] of PolicySection
    end

    # Loads a policy document, strictly: anything POLICY.md §1 refuses
    # raises InvalidPolicyError naming where. Two of `sections`
    # claiming one key raise ArgumentError, before the document is read.
    def self.from_yaml(source : String, sections : Array(PolicySection) = default_sections) : Policy
      check_claims!(sections)
      begin
        doc = YAML.parse(source)
        top = YamlPolicy.mapping(doc, "the document", TOP_KEYS) unless doc.raw.nil?
        risk_flow = YamlPolicy.value(top, "risk_flow")
        unless risk_flow
          raise YamlPolicy.invalid("the document", "needs a `risk_flow:` section; write `risk_flow: none` to judge no flows")
        end
        new(RiskFlowYaml.load(risk_flow), grants_from(top, sections))
      rescue ex : InvalidPolicyError
        raise ex
      rescue ex : YAML::ParseException
        raise InvalidPolicyError.new("the document is not valid YAML: #{ex.message}", cause: ex)
      rescue ex : InvalidRiskFlowPolicyError
        raise InvalidPolicyError.new("risk_flow: #{ex.message}", cause: ex)
      rescue ex : ArgumentError
        raise InvalidPolicyError.new(ex.message || ex.class.name, cause: ex)
      end
    end

    # The `grants:` and `limits:` sections of the mapping `top`, each
    # key parsed by the section that claims it, as Legate's Grants.
    private def self.grants_from(top : YamlPolicy::Mapping?, sections : Array(PolicySection)) : Legate::Grants
      grants = YamlPolicy.section(top, "grants", "grants", sections.flat_map(&.grant_keys))
      limits = YamlPolicy.section(top, "limits", "limits", sections.flat_map(&.limit_keys))
      shares = sections.map do |section|
        section.load(YamlPolicy.subset(grants, section.grant_keys), YamlPolicy.subset(limits, section.limit_keys))
      end
      core = shares.compact_map(&.as?(CorePolicyShare)).first?
      legate = shares.compact_map(&.as?(Legate::PolicyShare)).first?
      raise ArgumentError.new("a policy needs core's section and Legate's") unless core && legate
      legate.grants(core)
    end

    private def self.check_claims!(sections : Array(PolicySection)) : Nil
      owners = {} of String => String
      sections.each do |section|
        claims = section.grant_keys.map { |key| "grants.#{key}" } + section.limit_keys.map { |key| "limits.#{key}" }
        claims.each do |claim|
          if owner = owners[claim]?
            raise ArgumentError.new("#{claim} is claimed by both #{owner} and #{section.name}")
          end
          owners[claim] = section.name
        end
      end
    end
  end

  # Reads a policy document's `risk_flow` section (POLICY.md §4).
  module RiskFlowYaml
    TOP_KEYS     = {"patterns", "rules", "default"}
    PATTERN_KEYS = {"kind", "type", "pattern", "priority", "sensitivity"}
    RULE_KEYS    = {"authority", "sensitivity", "action", "priority", "origin", "subject"}
    ORIGIN_KEYS  = {"kind", "type", "pattern"}
    SUBJECT_KEYS = {"type", "pattern"}

    # `none` judges no flows; a mapping needs patterns or rules, since
    # one with neither would judge nothing while reading as if it did.
    def self.load(node : YAML::Any) : RiskFlowPolicy
      return RiskFlowPolicy.reject_all if node.as_s? == "none"
      unless node.as_h?
        raise YamlPolicy.invalid("risk_flow", "must be `none` or a mapping, got #{YamlPolicy.describe(node)}")
      end
      top = YamlPolicy.mapping(node, "risk_flow", TOP_KEYS)
      patterns = YamlPolicy.list(top, "patterns", "risk_flow.patterns")
      rules = YamlPolicy.list(top, "rules", "risk_flow.rules")
      if patterns.empty? && rules.empty?
        raise YamlPolicy.invalid("risk_flow", "has neither patterns nor rules; write `risk_flow: none` to judge no flows")
      end
      RiskFlowPolicy.new(
        sensitivity_patterns: patterns.map_with_index { |entry, index| pattern_of(entry, "risk_flow.patterns[#{index}]") },
        risk_flow_rules: rules.map_with_index { |entry, index| rule_of(entry, "risk_flow.rules[#{index}]") },
        default_action: YamlPolicy.choice(top, "default", "risk_flow.default", RiskFlowAction),
      )
    end

    private def self.pattern_of(entry : YAML::Any, path : String) : SensitivityPattern
      hash = YamlPolicy.mapping(entry, path, PATTERN_KEYS)
      SensitivityPattern.new(
        kind: YamlPolicy.choice(hash, "kind", "#{path}.kind", ProvenanceKind) || raise(needs(path, "kind")),
        pattern: YamlPolicy.string(hash, "pattern", "#{path}.pattern") || raise(needs(path, "pattern")),
        priority: YamlPolicy.integer(hash, "priority", "#{path}.priority") || raise(needs(path, "priority")),
        sensitivity: YamlPolicy.choice(hash, "sensitivity", "#{path}.sensitivity", Sensitivity) || raise(needs(path, "sensitivity")),
        pattern_type: YamlPolicy.choice(hash, "type", "#{path}.type", PatternType) || PatternType::Exact,
      )
    end

    private def self.rule_of(entry : YAML::Any, path : String) : RiskFlowRule
      hash = YamlPolicy.mapping(entry, path, RULE_KEYS)
      RiskFlowRule.new(
        authority: YamlPolicy.choice(hash, "authority", "#{path}.authority", Authority) || raise(needs(path, "authority")),
        sensitivity: YamlPolicy.choice(hash, "sensitivity", "#{path}.sensitivity", Sensitivity) || raise(needs(path, "sensitivity")),
        action: YamlPolicy.choice(hash, "action", "#{path}.action", RiskFlowAction) || raise(needs(path, "action")),
        origin: YamlPolicy.value(hash, "origin").try { |node| origin_of(node, "#{path}.origin") },
        subject: YamlPolicy.value(hash, "subject").try { |node| subject_of(node, "#{path}.subject") },
        priority: YamlPolicy.integer(hash, "priority", "#{path}.priority"),
      )
    end

    private def self.origin_of(node : YAML::Any, path : String) : RiskFlowOrigin
      hash = YamlPolicy.mapping(node, path, ORIGIN_KEYS)
      RiskFlowOrigin.new(
        kind: YamlPolicy.choice(hash, "kind", "#{path}.kind", ProvenanceKind) || raise(needs(path, "kind")),
        pattern: YamlPolicy.string(hash, "pattern", "#{path}.pattern") || raise(needs(path, "pattern")),
        pattern_type: YamlPolicy.choice(hash, "type", "#{path}.type", PatternType) || PatternType::Exact,
      )
    end

    private def self.subject_of(node : YAML::Any, path : String) : RiskFlowSubject
      hash = YamlPolicy.mapping(node, path, SUBJECT_KEYS)
      RiskFlowSubject.new(
        pattern: YamlPolicy.string(hash, "pattern", "#{path}.pattern") || raise(needs(path, "pattern")),
        pattern_type: YamlPolicy.choice(hash, "type", "#{path}.type", PatternType) || PatternType::Exact,
      )
    end

    private def self.needs(path : String, key : String) : InvalidPolicyError
      YamlPolicy.invalid(path, "needs a `#{key}:` key")
    end
  end
end
