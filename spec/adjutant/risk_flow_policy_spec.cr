require "../spec_helper"

# The form Legate names a file in, which an exact File pattern is
# matched in: `/etc` is `/private/etc` on macOS.
private def real(path : String) : String
  Adjutant::RealPath.of(path) || path
end

module Adjutant
  describe SensitivityPattern do
    it "exact is the default pattern_type" do
      p = SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High)
      p.pattern_type.should eq PatternType::Exact
    end

    it "exact matches only the literal origin" do
      p = SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High)
      p.matches?(real("/etc/passwd")).should be_true
      p.matches?(real("/etc/passwd2")).should be_false
      p.matches?(real("/etc/pass")).should be_false
    end

    it "regex matches per the given pattern" do
      p = SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex)
      p.matches?("/etc/hosts").should be_true
      p.matches?("/etc/passwd").should be_true
      p.matches?("/opt/etc/hosts").should be_false
    end

    it "matches an exact Host pattern as hosts compare, whatever its case or trailing dot" do
      p = SensitivityPattern.new(ProvenanceKind::Host, "https://EVIL.Example.:443", 10, Sensitivity::High)
      p.matches?("https://evil.example:443").should be_true
    end

  end

  describe RiskFlowPolicy do
    describe "#sensitivity_for" do
      it "returns None when nothing matches" do
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject)
        policy.sensitivity_for(ProvenanceKind::File, "/tmp/scratch").should eq Sensitivity::None
      end

      it "returns the sensitivity of the single matching rule" do
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject, sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
        ])
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/passwd")).should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/hosts")).should eq Sensitivity::None
      end

      it "does not cross-match a different ProvenanceKind with the same origin string" do
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject, sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::Host, "example.com", 10, Sensitivity::High),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "example.com").should eq Sensitivity::None
      end

      it "highest priority wins among several matching rules" do
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject, sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/hosts", 10, Sensitivity::None),
        ])
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/passwd")).should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/hosts")).should eq Sensitivity::None
        # Only the broad regex rule matches — nothing more specific for this path.
        policy.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
      end

      it "priority order does not depend on array order" do
        # Same rules as above but with the specific ones listed first —
        # result must be identical, since priority (not array position)
        # decides the winner.
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject, sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/hosts", 10, Sensitivity::None),
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
        ])
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/passwd")).should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/hosts")).should eq Sensitivity::None
      end

      # Two regexes, since a tie certain to arise is refused when the
      # policy is built ("ties found when built").
      it "raises AmbiguousRiskFlowPolicyError when two rules tie at the top priority" do
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject, sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/", 5, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "passwd$", 5, Sensitivity::High, PatternType::Regex),
        ])
        # Keeps its own exception class rather than becoming a
        # HostArgumentError: an ambiguous policy is about configuration
        # state, not any one call's arguments.
        error = expect_raises(AmbiguousRiskFlowPolicyError) do
          policy.sensitivity_for(ProvenanceKind::File, real("/etc/passwd"))
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("H003")
        diag.data["count"].should eq("2")
        diag.data["priority"].should eq("5")
      end

      it "does not raise for an origin that only hits the non-tied rule" do
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject, sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/", 5, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "passwd$", 5, Sensitivity::High, PatternType::Regex),
        ])
        # /etc/hosts matches only the first regex: no tie.
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::Elevated
      end
    end

    describe "#action_for" do
      it "always allows Sensitivity::None regardless of table contents" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(Authority::Delete, Sensitivity::None, RiskFlowAction::Reject),
        ], default_action: RiskFlowAction::Reject)
        action, rule = policy.action_for(Authority::Delete, Sensitivity::None)
        action.should eq RiskFlowAction::Allow
        rule.should be_nil
      end

      it "returns the default and no matched rule when no rule names the pair" do
        policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Ask)
        action, rule = policy.action_for(Authority::Net, Sensitivity::High)
        action.should eq RiskFlowAction::Ask
        rule.should be_nil
      end

      it "returns the matching rule's action and the rule itself" do
        ask_rule = RiskFlowRule.new(Authority::Delete, Sensitivity::Elevated, RiskFlowAction::Ask)
        reject_rule = RiskFlowRule.new(Authority::Write, Sensitivity::High, RiskFlowAction::Reject)
        policy = RiskFlowPolicy.new(risk_flow_rules: [ask_rule, reject_rule], default_action: RiskFlowAction::Reject)

        action, rule = policy.action_for(Authority::Delete, Sensitivity::Elevated)
        action.should eq RiskFlowAction::Ask
        rule.should eq ask_rule

        action2, rule2 = policy.action_for(Authority::Write, Sensitivity::High)
        action2.should eq RiskFlowAction::Reject
        rule2.should eq reject_rule
      end

      it "does not cross-match a different authority with the same sensitivity" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(Authority::Delete, Sensitivity::High, RiskFlowAction::Reject),
        ], default_action: RiskFlowAction::Ask)
        action, rule = policy.action_for(Authority::Net, Sensitivity::High)
        action.should eq RiskFlowAction::Ask
        rule.should be_nil
      end
    end

    # Exceptions: rules with an origin or subject pattern, overriding
    # the base rule for their pair.
    describe "#action_for with exceptions" do
      stripe_key = ProvenanceTag.new(ProvenanceKind::Env, "STRIPE_KEY", Sensitivity::High)
      github_token = ProvenanceTag.new(ProvenanceKind::Env, "GITHUB_TOKEN", Sensitivity::High)
      stripe = "https://api.stripe.com:443"
      elsewhere = "https://example.com:443"

      base = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Reject)
      key_to_stripe = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
        origin: RiskFlowOrigin.new(ProvenanceKind::Env, "STRIPE_KEY"),
        subject: RiskFlowSubject.new(stripe), priority: 10)

      it "applies to its origin at its subject" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_to_stripe], default_action: RiskFlowAction::Reject)
        action, rule = policy.action_for(Authority::Net, stripe_key, stripe)
        action.should eq RiskFlowAction::Allow
        rule.should eq key_to_stripe
      end

      it "leaves the base rule in force for another origin at the same subject" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_to_stripe], default_action: RiskFlowAction::Reject)
        action, rule = policy.action_for(Authority::Net, github_token, stripe)
        action.should eq RiskFlowAction::Reject
        rule.should eq base
      end

      it "leaves the base rule in force for its origin at another subject" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_to_stripe], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, stripe_key, elsewhere)[0].should eq RiskFlowAction::Reject
      end

      it "matches an exact URL subject as hosts compare, whatever its case or trailing dot" do
        respelled = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
          origin: RiskFlowOrigin.new(ProvenanceKind::Env, "STRIPE_KEY"),
          subject: RiskFlowSubject.new("https://API.Stripe.com.:443"), priority: 10)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, respelled], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, stripe_key, stripe)[0].should eq RiskFlowAction::Allow
      end

      it "never applies a subject pattern where the subject is unknown" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_to_stripe], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, stripe_key, nil)[0].should eq RiskFlowAction::Reject
      end

      it "applies an origin-only exception at any subject, known or not" do
        key_anywhere = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Ask,
          origin: RiskFlowOrigin.new(ProvenanceKind::Env, "STRIPE_KEY"), priority: 10)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_anywhere], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, stripe_key, elsewhere)[0].should eq RiskFlowAction::Ask
        policy.action_for(Authority::Net, stripe_key, nil)[0].should eq RiskFlowAction::Ask
      end

      it "matches an origin of the named kind only" do
        file_named_like_key = ProvenanceTag.new(ProvenanceKind::File, "STRIPE_KEY", Sensitivity::High)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_to_stripe], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, file_named_like_key, stripe)[0].should eq RiskFlowAction::Reject
      end

      it "matches a regex subject" do
        any_stripe = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
          origin: RiskFlowOrigin.new(ProvenanceKind::Env, "STRIPE_KEY"),
          subject: RiskFlowSubject.new("^https://[a-z]+\\.stripe\\.com:443$", PatternType::Regex), priority: 10)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, any_stripe], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, stripe_key, "https://files.stripe.com:443")[0].should eq RiskFlowAction::Allow
        policy.action_for(Authority::Net, stripe_key, "https://stripe.com.evil.example:443")[0].should eq RiskFlowAction::Reject
      end

      it "picks the highest-priority matching exception" do
        ask_anywhere = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Ask,
          origin: RiskFlowOrigin.new(ProvenanceKind::Env, "STRIPE_KEY"), priority: 5)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, ask_anywhere, key_to_stripe], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, stripe_key, stripe)[0].should eq RiskFlowAction::Allow
        policy.action_for(Authority::Net, stripe_key, elsewhere)[0].should eq RiskFlowAction::Ask
      end

      # Regexes on both sides, since a tie certain to arise is refused
      # when the policy is built ("ties found when built").
      it "raises on matching exceptions tied at the top priority" do
        key_pattern = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
          origin: RiskFlowOrigin.new(ProvenanceKind::Env, "^STRIPE", PatternType::Regex),
          subject: RiskFlowSubject.new("stripe", PatternType::Regex), priority: 10)
        rival = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Reject,
          origin: RiskFlowOrigin.new(ProvenanceKind::Env, "_KEY$", PatternType::Regex),
          subject: RiskFlowSubject.new("api\\.", PatternType::Regex), priority: 10)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_pattern, rival], default_action: RiskFlowAction::Reject)
        expect_raises(AmbiguousRiskFlowPolicyError) do
          policy.action_for(Authority::Net, stripe_key, stripe)
        end
      end

      it "doesn't apply an exception for another sensitivity" do
        elevated_key = ProvenanceTag.new(ProvenanceKind::Env, "STRIPE_KEY", Sensitivity::Elevated)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_to_stripe], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, elevated_key, stripe)[0].should eq RiskFlowAction::Reject
      end

      it "still allows Sensitivity::None whatever the exceptions say" do
        public_value = ProvenanceTag.new(ProvenanceKind::Env, "LANG", Sensitivity::None)
        policy = RiskFlowPolicy.new(risk_flow_rules: [base, key_to_stripe], default_action: RiskFlowAction::Reject)
        policy.action_for(Authority::Net, public_value, elsewhere)[0].should eq RiskFlowAction::Allow
      end

      it "rejects everything under reject_all, which takes no rules" do
        RiskFlowPolicy.reject_all.action_for(Authority::Net, stripe_key, stripe)[0].should eq RiskFlowAction::Reject
      end
    end

    describe "exception validity" do
      it "rejects an exception without a priority" do
        expect_raises(InvalidRiskFlowPolicyError, /priority/) do
          RiskFlowPolicy.new(risk_flow_rules: [
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
              subject: RiskFlowSubject.new("https://api.stripe.com:443")),
          ], default_action: RiskFlowAction::Reject)
        end
      end

      it "rejects a base rule with a priority" do
        expect_raises(InvalidRiskFlowPolicyError, /priority/) do
          RiskFlowPolicy.new(risk_flow_rules: [
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow, priority: 10),
          ], default_action: RiskFlowAction::Reject)
        end
      end

      it "rejects two base rules for one pair" do
        expect_raises(InvalidRiskFlowPolicyError, %r{Net/High}) do
          RiskFlowPolicy.new(risk_flow_rules: [
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow),
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Reject),
          ], default_action: RiskFlowAction::Reject)
        end
      end

      it "doesn't count an exception as covering its pair" do
        rules = RiskFlowPolicy.required_pairs.reject { |pair| pair == {Authority::Net, Sensitivity::High} }.map do |authority, sensitivity|
          RiskFlowRule.new(authority, sensitivity, RiskFlowAction::Reject)
        end
        rules << RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
          subject: RiskFlowSubject.new("https://api.stripe.com:443"), priority: 10)
        expect_raises(InvalidRiskFlowPolicyError, %r{Net/High}) do
          RiskFlowPolicy.new(risk_flow_rules: rules)
        end
      end

      it "loads an exception from a policy document that matches as built" do
        parsed = Policy.from_yaml(<<-YAML).risk_flow
          risk_flow:
            rules:
              - { authority: net, sensitivity: high, action: reject }
              - authority: net
                sensitivity: high
                action: allow
                priority: 10
                origin: { kind: env, pattern: STRIPE_KEY }
                subject: { pattern: "https://api.stripe.com:443" }
            default: reject
          YAML
        key = ProvenanceTag.new(ProvenanceKind::Env, "STRIPE_KEY", Sensitivity::High)
        parsed.action_for(Authority::Net, key, "https://api.stripe.com:443")[0].should eq RiskFlowAction::Allow
        parsed.action_for(Authority::Net, key, "https://example.com:443")[0].should eq RiskFlowAction::Reject
      end
    end

    # A regex that doesn't compile is the host's configuration error,
    # so it is refused when the pattern is built, not when a value
    # first meets it inside a native call a script might rescue.
    describe "regex validity" do
      it "rejects an invalid regex in a sensitivity pattern" do
        expect_raises(InvalidRiskFlowPolicyError, /\[a-/) do
          SensitivityPattern.new(ProvenanceKind::Env, "[a-", 10, Sensitivity::High, PatternType::Regex)
        end
      end

      it "rejects an invalid regex in an exception's origin" do
        expect_raises(InvalidRiskFlowPolicyError, /\[a-/) do
          RiskFlowOrigin.new(ProvenanceKind::Env, "[a-", PatternType::Regex)
        end
      end

      it "rejects an invalid regex in an exception's subject" do
        expect_raises(InvalidRiskFlowPolicyError, /\[a-/) do
          RiskFlowSubject.new("[a-", PatternType::Regex)
        end
      end

      it "rejects an invalid regex in a policy document" do
        expect_raises(InvalidPolicyError, /\[a-/) do
          Policy.from_yaml(<<-YAML)
            risk_flow:
              patterns:
                - { kind: env, type: regex, pattern: "[a-", priority: 10, sensitivity: high }
              default: reject
            YAML
        end
      end

      it "accepts the same text as an exact pattern" do
        SensitivityPattern.new(ProvenanceKind::Env, "[a-", 10, Sensitivity::High).matches?("[a-").should be_true
      end
    end

    # A tie certain to arise is refused when the policy is built, where
    # its author sees it. One only a real origin or subject reveals,
    # such as between two different regexes, waits for H003.
    describe "ties found when built" do
      key = RiskFlowOrigin.new(ProvenanceKind::Env, "STRIPE_KEY")
      stripe = RiskFlowSubject.new("https://api.stripe.com:443")
      reject = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Reject)

      it "rejects two sensitivity patterns that say the same thing at one priority" do
        expect_raises(InvalidRiskFlowPolicyError, /would tie/) do
          RiskFlowPolicy.new(sensitivity_patterns: [
            SensitivityPattern.new(ProvenanceKind::Env, "STRIPE_KEY", 10, Sensitivity::High),
            SensitivityPattern.new(ProvenanceKind::Env, "STRIPE_KEY", 10, Sensitivity::Elevated),
          ], default_action: RiskFlowAction::Reject)
        end
      end

      it "rejects a regex matching an exact pattern at the same priority" do
        expect_raises(InvalidRiskFlowPolicyError, /would tie/) do
          RiskFlowPolicy.new(sensitivity_patterns: [
            SensitivityPattern.new(ProvenanceKind::Env, "STRIPE_KEY", 10, Sensitivity::High),
            SensitivityPattern.new(ProvenanceKind::Env, "_KEY$", 10, Sensitivity::Elevated, PatternType::Regex),
          ], default_action: RiskFlowAction::Reject)
        end
      end

      it "loads them when a higher-priority pattern decides the exact one's origin" do
        RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::Env, "STRIPE_KEY", 10, Sensitivity::High),
          SensitivityPattern.new(ProvenanceKind::Env, "_KEY$", 10, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::Env, "STRIPE_KEY", 20, Sensitivity::High),
        ], default_action: RiskFlowAction::Reject)
      end

      it "loads two different regexes at one priority" do
        RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::Env, "^STRIPE", 10, Sensitivity::High, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::Env, "_KEY$", 10, Sensitivity::Elevated, PatternType::Regex),
        ], default_action: RiskFlowAction::Reject)
      end

      it "loads patterns of different kinds at one priority" do
        RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::Env, "STRIPE_KEY", 10, Sensitivity::High),
          SensitivityPattern.new(ProvenanceKind::UserInput, "STRIPE_KEY", 10, Sensitivity::Elevated),
        ], default_action: RiskFlowAction::Reject)
      end

      it "rejects two exceptions with the same scope at one priority" do
        expect_raises(InvalidRiskFlowPolicyError, /would tie/) do
          RiskFlowPolicy.new(risk_flow_rules: [
            reject,
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow, origin: key, subject: stripe, priority: 10),
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Ask, origin: key, subject: stripe, priority: 10),
          ], default_action: RiskFlowAction::Reject)
        end
      end

      it "rejects exceptions that certainly both apply to one flow at one priority" do
        expect_raises(InvalidRiskFlowPolicyError, /would tie/) do
          RiskFlowPolicy.new(risk_flow_rules: [
            reject,
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow, origin: key, subject: stripe, priority: 10),
            RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Ask,
              subject: RiskFlowSubject.new("stripe\\.com", PatternType::Regex), priority: 10),
          ], default_action: RiskFlowAction::Reject)
        end
      end

      it "loads them when a higher-priority exception decides that flow" do
        RiskFlowPolicy.new(risk_flow_rules: [
          reject,
          RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow, origin: key, subject: stripe, priority: 10),
          RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Ask,
            subject: RiskFlowSubject.new("stripe\\.com", PatternType::Regex), priority: 10),
          RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow, subject: stripe, priority: 20),
        ], default_action: RiskFlowAction::Reject)
      end

      it "loads exceptions whose overlap only a real flow could show" do
        RiskFlowPolicy.new(risk_flow_rules: [
          reject,
          RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
            origin: RiskFlowOrigin.new(ProvenanceKind::Env, "^STRIPE", PatternType::Regex), priority: 10),
          RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Ask,
            origin: RiskFlowOrigin.new(ProvenanceKind::Env, "_KEY$", PatternType::Regex), priority: 10),
        ], default_action: RiskFlowAction::Reject)
      end

      it "rejects a certain tie in a policy document" do
        expect_raises(InvalidPolicyError, /would tie/) do
          Policy.from_yaml(<<-YAML)
            risk_flow:
              patterns:
                - { kind: env, pattern: STRIPE_KEY, priority: 10, sensitivity: high }
                - { kind: env, pattern: STRIPE_KEY, priority: 10, sensitivity: elevated }
              default: reject
            YAML
        end
      end
    end

    # A gap in a policy must reach its author when it is built, not an
    # unattended run when a flow first meets it.
    describe "completeness" do
      it "rejects a policy that leaves pairs to no rule and no default, naming each" do
        rules = RiskFlowPolicy.required_pairs.reject { |authority, _| authority.write? }.map do |authority, sensitivity|
          RiskFlowRule.new(authority, sensitivity, RiskFlowAction::Ask)
        end
        error = expect_raises(InvalidRiskFlowPolicyError) do
          RiskFlowPolicy.new(risk_flow_rules: rules)
        end
        error.message.not_nil!.should contain "Write/Elevated, Write/High"
      end

      it "requires Ambient, which Legate.env consults for a variable's own sensitivity" do
        rules = RiskFlowPolicy.required_pairs.reject { |authority, _| authority.ambient? }.map do |authority, sensitivity|
          RiskFlowRule.new(authority, sensitivity, RiskFlowAction::Ask)
        end
        expect_raises(InvalidRiskFlowPolicyError, /Ambient\/Elevated, Ambient\/High/) do
          RiskFlowPolicy.new(risk_flow_rules: rules)
        end
      end

      it "accepts a policy whose rules name every pair" do
        rules = RiskFlowPolicy.required_pairs.map do |authority, sensitivity|
          RiskFlowRule.new(authority, sensitivity, RiskFlowAction::Allow)
        end
        RiskFlowPolicy.new(risk_flow_rules: rules).action_for(Authority::Log, Sensitivity::High)[0].should eq RiskFlowAction::Allow
      end

      it "rejects a default of Allow" do
        expect_raises(InvalidRiskFlowPolicyError, /not Allow/) do
          RiskFlowPolicy.new(default_action: RiskFlowAction::Allow)
        end
      end

    end

    describe ".reject_all" do
      it "rejects any non-None sensitivity regardless of risk_flow_rules" do
        policy = RiskFlowPolicy.reject_all
        policy.action_for(Authority::Net, Sensitivity::Elevated)[0].should eq RiskFlowAction::Reject
        policy.action_for(Authority::Delete, Sensitivity::High)[0].should eq RiskFlowAction::Reject
        policy.action_for(Authority::Write, Sensitivity::High)[0].should eq RiskFlowAction::Reject
      end

      it "still allows Sensitivity::None" do
        policy = RiskFlowPolicy.reject_all
        action, rule = policy.action_for(Authority::Net, Sensitivity::None)
        action.should eq RiskFlowAction::Allow
        rule.should be_nil
      end

      it "does not need any risk_flow_rules configured" do
        policy = RiskFlowPolicy.reject_all
        policy.risk_flow_rules.should be_empty
      end

      it "returns no matched rule even when rejecting, since reject_all is not a rule" do
        policy = RiskFlowPolicy.reject_all
        _, rule = policy.action_for(Authority::Net, Sensitivity::High)
        rule.should be_nil
      end

      it "is never what a policy document's rules load as" do
        policy = Policy.from_yaml(<<-YAML).risk_flow
          risk_flow:
            rules:
              - { authority: delete, sensitivity: high, action: ask }
            default: ask
          YAML
        policy.reject_all_flows?.should be_false
        policy.action_for(Authority::Net, Sensitivity::High)[0].should eq RiskFlowAction::Ask
      end
    end

    describe "loaded from a policy document" do
      it "loads patterns, rules and a default" do
        parsed = Policy.from_yaml(<<-YAML).risk_flow
          risk_flow:
            patterns:
              - { kind: file, pattern: /etc/passwd, priority: 10, sensitivity: high }
              - { kind: file, type: regex, pattern: "^/etc/", priority: 0, sensitivity: elevated }
            rules:
              - { authority: delete, sensitivity: elevated, action: ask }
              - { authority: write, sensitivity: high, action: reject }
            default: ask
          YAML
        parsed.default_action.should eq RiskFlowAction::Ask
        parsed.sensitivity_for(ProvenanceKind::File, real("/etc/passwd")).should eq Sensitivity::High
        parsed.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
        parsed.action_for(Authority::Delete, Sensitivity::Elevated)[0].should eq RiskFlowAction::Ask
        parsed.action_for(Authority::Write, Sensitivity::High)[0].should eq RiskFlowAction::Reject
      end

      it "loads the design doc's worked example" do
        policy = Policy.from_yaml(<<-'YAML').risk_flow
          risk_flow:
            patterns:
              - { kind: file, pattern: /etc/passwd, priority: 10, sensitivity: high }
              - { kind: file, pattern: /etc/hosts, priority: 10, sensitivity: none }
              - { kind: file, type: regex, pattern: '^/etc/', priority: 0, sensitivity: elevated }
              - { kind: host, type: regex, pattern: '\.com$', priority: 0, sensitivity: elevated }
              - { kind: host, type: regex, pattern: '\.gmail\.com$', priority: 5, sensitivity: high }
              - { kind: host, pattern: mybiz.example.com, priority: 10, sensitivity: none }
            rules:
              - { authority: delete, sensitivity: elevated, action: ask }
              - { authority: delete, sensitivity: high, action: ask }
              - { authority: net, sensitivity: high, action: ask }
              - { authority: write, sensitivity: high, action: reject }
            default: ask
          YAML
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/passwd")).should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, real("/etc/hosts")).should eq Sensitivity::None
        policy.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
        policy.sensitivity_for(ProvenanceKind::Host, "mail.gmail.com").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::Host, "mybiz.example.com").should eq Sensitivity::None
        policy.sensitivity_for(ProvenanceKind::Host, "other.com").should eq Sensitivity::Elevated
        policy.action_for(Authority::Delete, Sensitivity::Elevated)[0].should eq RiskFlowAction::Ask
        policy.action_for(Authority::Write, Sensitivity::High)[0].should eq RiskFlowAction::Reject
      end
    end
  end

  describe "Interpreter risk_flow_policy wiring" do
    it "accepts a RiskFlowPolicy at construction" do
      ef = TestEffectHandler.new
      policy = RiskFlowPolicy.new(default_action: RiskFlowAction::Reject, sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
      ])
      interp = Interpreter.new(
        policy: Policy.new(policy),
        on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
        effect: ef,
      )
      interp.risk_flow_policy.should be policy
      interp.risk_flow_policy.sensitivity_for(ProvenanceKind::File, real("/etc/passwd")).should eq Sensitivity::High
    end

    it "policy and on_risk_flow_decision are required (no bare Interpreter.new default)" do
      # make_interp supplies both explicitly via spec_helper's shared
      # TEST_REJECT_ALL_POLICY/TEST_UNEXPECTED_ASK_CALLBACK defaults —
      # there is no Interpreter.new() with zero args, by design.
      interp, _ = make_interp
      interp.risk_flow_policy.should be TEST_REJECT_ALL_POLICY
    end
  end
end
