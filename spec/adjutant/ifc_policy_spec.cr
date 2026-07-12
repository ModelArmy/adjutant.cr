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

  describe IFCPolicy do
    describe "#sensitivity_for" do
      it "returns None when nothing matches" do
        policy = IFCPolicy.new
        policy.sensitivity_for(ProvenanceKind::File, "/tmp/scratch").should eq Sensitivity::None
      end

      it "returns the sensitivity of the single matching rule" do
        policy = IFCPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::None
      end

      it "does not cross-match a different ProvenanceKind with the same origin string" do
        policy = IFCPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::Host, "example.com", 10, Sensitivity::High),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "example.com").should eq Sensitivity::None
      end

      it "highest priority wins among several matching rules" do
        policy = IFCPolicy.new(sensitivity_patterns: [
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
        policy = IFCPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/hosts", 10, Sensitivity::None),
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
        ])
        policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::None
      end

      it "raises AmbiguousPolicyError when two rules tie at the top priority" do
        policy = IFCPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 5, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 5, Sensitivity::High),
        ])
        expect_raises(AmbiguousPolicyError) do
          policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd")
        end
      end

      it "does not raise for an origin that only hits the non-tied rule" do
        policy = IFCPolicy.new(sensitivity_patterns: [
          SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 5, Sensitivity::Elevated, PatternType::Regex),
          SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 5, Sensitivity::High),
        ])
        # /etc/hosts only matches the regex rule, not the exact one — no tie.
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::Elevated
      end
    end

    describe "#action_for" do
      it "always allows Sensitivity::None regardless of table contents" do
        policy = IFCPolicy.new(sink_rules: [
          SinkRule.new(RiskTag::DeletesFiles, Sensitivity::None, SinkAction::Reject),
        ])
        policy.action_for(RiskTag::DeletesFiles, Sensitivity::None).should eq SinkAction::Allow
      end

      it "returns Allow when no rule matches a non-None sensitivity" do
        policy = IFCPolicy.new
        policy.action_for(RiskTag::NetworkEgress, Sensitivity::High).should eq SinkAction::Allow
      end

      it "returns the matching rule's action" do
        policy = IFCPolicy.new(sink_rules: [
          SinkRule.new(RiskTag::DeletesFiles, Sensitivity::Elevated, SinkAction::Ask),
          SinkRule.new(RiskTag::ElevatedPrivilege, Sensitivity::High, SinkAction::Reject),
        ])
        policy.action_for(RiskTag::DeletesFiles, Sensitivity::Elevated).should eq SinkAction::Ask
        policy.action_for(RiskTag::ElevatedPrivilege, Sensitivity::High).should eq SinkAction::Reject
      end

      it "does not cross-match a different RiskTag with the same sensitivity" do
        policy = IFCPolicy.new(sink_rules: [
          SinkRule.new(RiskTag::DeletesFiles, Sensitivity::High, SinkAction::Reject),
        ])
        policy.action_for(RiskTag::NetworkEgress, Sensitivity::High).should eq SinkAction::Allow
      end
    end

    describe "JSON round-trip" do
      it "round-trips a full policy" do
        original = IFCPolicy.new(
          sensitivity_patterns: [
            SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
            SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
          ],
          sink_rules: [
            SinkRule.new(RiskTag::DeletesFiles, Sensitivity::Elevated, SinkAction::Ask),
            SinkRule.new(RiskTag::ElevatedPrivilege, Sensitivity::High, SinkAction::Reject),
          ]
        )
        parsed = IFCPolicy.from_json(original.to_json)
        parsed.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        parsed.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
        parsed.action_for(RiskTag::DeletesFiles, Sensitivity::Elevated).should eq SinkAction::Ask
        parsed.action_for(RiskTag::ElevatedPrivilege, Sensitivity::High).should eq SinkAction::Reject
      end

      it "parses the design doc's worked example" do
        # Built via IFCPolicy.new + to_json rather than a literal JSON
        # heredoc, to avoid backslash-escaping ambiguity (heredoc source
        # -> Crystal string -> JSON text -> regex engine is four layers
        # of escaping to get right by hand) while still exercising the
        # same JSON round-trip path as loading a real policy file would.
        original = IFCPolicy.new(
          sensitivity_patterns: [
            SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
            SensitivityPattern.new(ProvenanceKind::File, "/etc/hosts", 10, Sensitivity::None),
            SensitivityPattern.new(ProvenanceKind::File, "^/etc/", 0, Sensitivity::Elevated, PatternType::Regex),
            SensitivityPattern.new(ProvenanceKind::Host, "\\.com$", 0, Sensitivity::Elevated, PatternType::Regex),
            SensitivityPattern.new(ProvenanceKind::Host, "\\.gmail\\.com$", 5, Sensitivity::High, PatternType::Regex),
            SensitivityPattern.new(ProvenanceKind::Host, "mybiz.example.com", 10, Sensitivity::None),
          ],
          sink_rules: [
            SinkRule.new(RiskTag::DeletesFiles, Sensitivity::Elevated, SinkAction::Ask),
            SinkRule.new(RiskTag::DeletesFiles, Sensitivity::High, SinkAction::Ask),
            SinkRule.new(RiskTag::NetworkEgress, Sensitivity::High, SinkAction::Ask),
            SinkRule.new(RiskTag::ElevatedPrivilege, Sensitivity::High, SinkAction::Reject),
          ]
        )
        policy = IFCPolicy.from_json(original.to_json)
        policy.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::File, "/etc/hosts").should eq Sensitivity::None
        policy.sensitivity_for(ProvenanceKind::File, "/etc/shadow").should eq Sensitivity::Elevated
        policy.sensitivity_for(ProvenanceKind::Host, "mail.gmail.com").should eq Sensitivity::High
        policy.sensitivity_for(ProvenanceKind::Host, "mybiz.example.com").should eq Sensitivity::None
        policy.sensitivity_for(ProvenanceKind::Host, "other.com").should eq Sensitivity::Elevated
        policy.action_for(RiskTag::DeletesFiles, Sensitivity::Elevated).should eq SinkAction::Ask
        policy.action_for(RiskTag::ElevatedPrivilege, Sensitivity::High).should eq SinkAction::Reject
      end
    end
  end

  describe "Interpreter ifc_policy wiring" do
    it "defaults to no policy" do
      interp, _ = make_interp
      interp.ifc_policy.should be_nil
    end

    it "accepts an IFCPolicy at construction" do
      ef = TestEffectHandler.new
      policy = IFCPolicy.new(sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::File, "/etc/passwd", 10, Sensitivity::High),
      ])
      interp = Interpreter.new(effect: ef, ifc_policy: policy)
      interp.ifc_policy.should_not be_nil
      interp.ifc_policy.not_nil!.sensitivity_for(ProvenanceKind::File, "/etc/passwd").should eq Sensitivity::High
    end
  end
end
