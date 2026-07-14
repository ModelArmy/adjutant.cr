require "../spec_helper"

module Adjutant
  describe SensitivityPattern do
    it "exact is the default pattern_type" do
      p = SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High)
      p.pattern_type.should eq PatternType::Exact
    end

    it "exact matches only the literal origin" do
      p = SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High)
      p.matches?("/etc/passwd").should be_true
      p.matches?("/etc/passwd2").should be_false
      p.matches?("/etc/pass").should be_false
    end

    it "regex matches per the given pattern" do
      p = SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex)
      p.matches?("/etc/hosts").should be_true
      p.matches?("/etc/passwd").should be_true
      p.matches?("/opt/etc/hosts").should be_false
    end

    it "regex round-trips through JSON with pattern_type explicit" do
      original = SensitivityPattern.new(ProvenanceKind::Host, "\\.com$", 0, Sensitivity::Elevated, PatternType::Regex)
      parsed = SensitivityPattern.from_json(original.to_json)
      parsed.pattern_type.should eq PatternType::Regex
      parsed.matches?("example.com").should be_true
    end

    it "exact round-trips through JSON when pattern_type is omitted" do
      json = %({"kind":"File","pattern":"/etc/hosts","priority":10,"sensitivity":"None"})
      parsed = SensitivityPattern.from_json(json)
      parsed.pattern_type.should eq PatternType::Exact
      parsed.matches?("/etc/hosts").should be_true
    end
  end

  describe RiskFlowPolicy do
    describe "#sensitivity_for" do
      it "returns None when nothing matches" do
        policy = RiskFlowPolicy.new
        policy.sensitivity_for(ProvenanceKind::File, "/tmp/scratch").should eq Sensitivity::None
      end

      it "returns the sensitivity of the single matching rule" do
        policy = RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::None
      end

      it "does not cross-match a different ProvenanceKind with the same origin string" do
        policy = RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::Host, "example.com", 10, Sensitivity::High),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "example.com").should eq Sensitivity::None
      end

      it "highest priority wins among several matching rules" do
        policy = RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/hosts", 10, Sensitivity::None),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::None
        # Only the broad regex rule matches — nothing more specific for this path.
        policy.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
      end

      it "priority order does not depend on array order" do
        # Same rules as above but with the specific ones listed first —
        # result must be identical, since priority (not array position)
        # decides the winner.
        policy = RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/hosts", 10, Sensitivity::None),
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::None
      end

      it "raises AmbiguousRiskFlowPolicyError when two rules tie at the top priority" do
        policy = RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 5, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 5, Sensitivity::High),
        ])
        expect_raises(AmbiguousRiskFlowPolicyError) do
          policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd")
        end
      end

      it "does not raise for an origin that only hits the non-tied rule" do
        policy = RiskFlowPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 5, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 5, Sensitivity::High),
        ])
        # /etc/hosts only matches the regex rule, not the exact one — no tie.
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::Elevated
      end
    end

    describe "#action_for" do
      it "always allows Sensitivity::None regardless of table contents" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::None, RiskFlowAction::Reject),
        ])
        action, rule = policy.action_for(RiskTag::DeletesFiles, Sensitivity::None)
        action.should eq RiskFlowAction::Allow
        rule.should be_nil
      end

      it "returns Allow and no matched rule when no rule matches a non-None sensitivity" do
        policy = RiskFlowPolicy.new
        action, rule = policy.action_for(RiskTag::NetworkEgress, Sensitivity::High)
        action.should eq RiskFlowAction::Allow
        rule.should be_nil
      end

      it "returns the matching rule's action and the rule itself" do
        ask_rule = RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::Elevated, RiskFlowAction::Ask)
        reject_rule = RiskFlowRule.new(RiskTag::ElevatedPrivilege, Sensitivity::High, RiskFlowAction::Reject)
        policy = RiskFlowPolicy.new(risk_flow_rules: [ask_rule, reject_rule])

        action, rule = policy.action_for(RiskTag::DeletesFiles, Sensitivity::Elevated)
        action.should eq RiskFlowAction::Ask
        rule.should eq ask_rule

        action2, rule2 = policy.action_for(RiskTag::ElevatedPrivilege, Sensitivity::High)
        action2.should eq RiskFlowAction::Reject
        rule2.should eq reject_rule
      end

      it "does not cross-match a different RiskTag with the same sensitivity" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::High, RiskFlowAction::Reject),
        ])
        action, rule = policy.action_for(RiskTag::NetworkEgress, Sensitivity::High)
        action.should eq RiskFlowAction::Allow
        rule.should be_nil
      end
    end

    describe ".reject_all" do
      it "rejects any non-None sensitivity regardless of risk_flow_rules" do
        policy = RiskFlowPolicy.reject_all
        policy.action_for(RiskTag::NetworkEgress, Sensitivity::Elevated)[0].should eq RiskFlowAction::Reject
        policy.action_for(RiskTag::DeletesFiles, Sensitivity::High)[0].should eq RiskFlowAction::Reject
        policy.action_for(RiskTag::ElevatedPrivilege, Sensitivity::High)[0].should eq RiskFlowAction::Reject
      end

      it "still allows Sensitivity::None" do
        policy = RiskFlowPolicy.reject_all
        action, rule = policy.action_for(RiskTag::NetworkEgress, Sensitivity::None)
        action.should eq RiskFlowAction::Allow
        rule.should be_nil
      end

      it "does not need any risk_flow_rules configured" do
        policy = RiskFlowPolicy.reject_all
        policy.risk_flow_rules.should be_empty
      end

      it "returns no matched rule even when rejecting, since reject_all is not a rule" do
        policy = RiskFlowPolicy.reject_all
        _, rule = policy.action_for(RiskTag::NetworkEgress, Sensitivity::High)
        rule.should be_nil
      end

      it "reject_all_flows is not part of the JSON representation" do
        policy = RiskFlowPolicy.reject_all
        policy.to_json.should_not contain("reject_all")
      end

      it "a loaded policy JSON (never containing reject_all_flows) does not accidentally reject everything" do
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::High, RiskFlowAction::Ask),
        ])
        parsed = RiskFlowPolicy.from_json(policy.to_json)
        parsed.reject_all_flows?.should be_false
        parsed.action_for(RiskTag::NetworkEgress, Sensitivity::High)[0].should eq RiskFlowAction::Allow
      end
    end

    describe "JSON round-trip" do
      it "round-trips a full policy" do
        original = RiskFlowPolicy.new(
          sensitivity_patterns: [
            SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
            SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
          ],
          risk_flow_rules: [
            RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::Elevated, RiskFlowAction::Ask),
            RiskFlowRule.new(RiskTag::ElevatedPrivilege, Sensitivity::High, RiskFlowAction::Reject),
          ]
        )
        parsed = RiskFlowPolicy.from_json(original.to_json)
        parsed.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        parsed.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
        parsed.action_for(RiskTag::DeletesFiles, Sensitivity::Elevated)[0].should eq RiskFlowAction::Ask
        parsed.action_for(RiskTag::ElevatedPrivilege, Sensitivity::High)[0].should eq RiskFlowAction::Reject
      end

      it "parses the design doc's worked example" do
        # Built via RiskFlowPolicy.new + to_json rather than a literal JSON
        # heredoc, to avoid backslash-escaping ambiguity (heredoc source
        # -> Crystal string -> JSON text -> regex engine is four layers
        # of escaping to get right by hand) while still exercising the
        # same JSON round-trip path as loading a real policy file would.
        original = RiskFlowPolicy.new(
          sensitivity_patterns: [
            SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
            SensitivityPattern.new(ProvenanceKind::File, "/etc/hosts", 10, Sensitivity::None),
            SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
            SensitivityPattern.new(ProvenanceKind::Host, "\\.com$", 0, Sensitivity::Elevated, PatternType::Regex),
            SensitivityPattern.new(ProvenanceKind::Host, "\\.gmail\\.com$", 5, Sensitivity::High, PatternType::Regex),
            SensitivityPattern.new(ProvenanceKind::Host, "mybiz.example.com", 10, Sensitivity::None),
          ],
          risk_flow_rules: [
            RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::Elevated, RiskFlowAction::Ask),
            RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::High, RiskFlowAction::Ask),
            RiskFlowRule.new(RiskTag::NetworkEgress, Sensitivity::High, RiskFlowAction::Ask),
            RiskFlowRule.new(RiskTag::ElevatedPrivilege, Sensitivity::High, RiskFlowAction::Reject),
          ]
        )
        policy = RiskFlowPolicy.from_json(original.to_json)
        policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::None
        policy.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
        policy.sensitivity_for(ProvenanceKind::Host, "mail.gmail.com").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::Host, "mybiz.example.com").should eq Sensitivity::None
        policy.sensitivity_for(ProvenanceKind::Host, "other.com").should eq Sensitivity::Elevated
        policy.action_for(RiskTag::DeletesFiles, Sensitivity::Elevated)[0].should eq RiskFlowAction::Ask
        policy.action_for(RiskTag::ElevatedPrivilege, Sensitivity::High)[0].should eq RiskFlowAction::Reject
      end
    end
  end

  describe "Interpreter risk_flow_policy wiring" do
    it "accepts a RiskFlowPolicy at construction" do
      ef = TestEffectHandler.new
      policy = RiskFlowPolicy.new(sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
      ])
      interp = Interpreter.new(
        risk_flow_policy: policy,
        on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
        effect: ef,
      )
      interp.risk_flow_policy.should be policy
      interp.risk_flow_policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
    end

    it "risk_flow_policy and on_risk_flow_decision are required (no bare Interpreter.new default)" do
      # make_interp supplies both explicitly via spec_helper's shared
      # TEST_REJECT_ALL_POLICY/TEST_UNEXPECTED_ASK_CALLBACK defaults —
      # there is no Interpreter.new() with zero args, by design.
      interp, _ = make_interp
      interp.risk_flow_policy.should be TEST_REJECT_ALL_POLICY
    end
  end
end
