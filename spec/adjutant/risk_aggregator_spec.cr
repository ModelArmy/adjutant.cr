require "../spec_helper"

module Adjutant
  private def self.leaf(effects : Set(Effect), severity : Severity, reversible : Reversibility = Reversibility::Yes,
                        note : String? = nil, desc = "call")
    RiskLeaf.new(RiskProfile.new(effects: effects, reversible: reversible, severity: severity, note: note), desc, 1)
  end

  private def self.pure_leaf(desc = "pure_call")
    RiskLeaf.new(RiskProfile.none, desc, 1)
  end

  describe RiskAggregator do
    it "an empty Sequence summarizes to none" do
      RiskAggregator.summarize(RiskSequence.new([] of RiskNode, 1)).should eq RiskSummary.none
    end

    it "a Sequence of pure leaves summarizes to none-equivalent" do
      seq = RiskSequence.new([pure_leaf, pure_leaf] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.effects.should be_empty
      summary.severity.should eq Severity::Info
    end

    it "a Sequence unions effects across all children (all occur)" do
      a = leaf(Set{Effect::ReadsFiles}, Severity::Info)
      b = leaf(Set{Effect::NetworkEgress}, Severity::Warning)
      seq = RiskSequence.new([a, b] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.effects.should eq Set{Effect::ReadsFiles, Effect::NetworkEgress}
      summary.severity.should eq Severity::Warning
    end

    it "a Sequence's severity/reversibility reflect the worst single child, not an average" do
      safe = leaf(Set{Effect::ReadsFiles}, Severity::Info)
      dangerous = leaf(Set{Effect::DeletesFiles}, Severity::Error, Reversibility::No)
      seq = RiskSequence.new([safe, dangerous] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.severity.should eq Severity::Error
      summary.reversible.should eq Reversibility::No
    end

    it "an iterated Sequence marks the summary as iterated" do
      seq = RiskSequence.new([leaf(Set{Effect::WritesFiles}, Severity::Warning)] of RiskNode, 1, iterated: true)
      RiskAggregator.summarize(seq).iterated?.should be_true
    end

    it "a Sequence takes severity and reversibility each from its own worst child" do
      severe = leaf(Set{Effect::ExecutesCode}, Severity::Error, Reversibility::Yes)
      irreversible = leaf(Set{Effect::DeletesFiles}, Severity::Warning, Reversibility::No)
      summary = RiskAggregator.summarize(RiskSequence.new([severe, irreversible] of RiskNode, 1))
      summary.severity.should eq Severity::Error
      summary.reversible.should eq Reversibility::No
    end

    it "a Choice unions its branches' effects and takes the worst severity and reversibility" do
      read_branch = leaf(Set{Effect::ReadsFiles}, Severity::Info)
      delete_branch = leaf(Set{Effect::DeletesFiles}, Severity::Error, Reversibility::No)
      choice = RiskChoice.new([read_branch, delete_branch] of RiskNode, "if", 1)
      summary = RiskAggregator.summarize(choice)
      summary.effects.should eq Set{Effect::ReadsFiles, Effect::DeletesFiles}
      summary.severity.should eq Severity::Error
      summary.reversible.should eq Reversibility::No
    end

    it "a Choice keeps the effects of a branch that ties with an earlier one" do
      fetch_branch = leaf(Set{Effect::NetworkEgress}, Severity::Warning, Reversibility::No)
      rmdir_branch = leaf(Set{Effect::DeletesFiles, Effect::Recursive}, Severity::Warning, Reversibility::No)
      choice = RiskChoice.new([fetch_branch, rmdir_branch] of RiskNode, "if", 1)
      RiskAggregator.summarize(choice).effects.should eq Set{Effect::NetworkEgress, Effect::DeletesFiles, Effect::Recursive}
    end

    it "a Choice takes severity and reversibility each from its own worst branch" do
      severe = leaf(Set{Effect::ExecutesCode}, Severity::Error, Reversibility::Yes)
      irreversible = leaf(Set{Effect::DeletesFiles}, Severity::Warning, Reversibility::No)
      summary = RiskAggregator.summarize(RiskChoice.new([severe, irreversible] of RiskNode, "case", 1))
      summary.severity.should eq Severity::Error
      summary.reversible.should eq Reversibility::No
    end

    it "a Choice is iterated when any branch is" do
      once = leaf(Set{Effect::DeletesFiles}, Severity::Error, Reversibility::No)
      looped = RiskSequence.new([leaf(Set{Effect::WritesFiles}, Severity::Warning)] of RiskNode, 1, iterated: true)
      choice = RiskChoice.new([once, looped] of RiskNode, "if", 1)
      RiskAggregator.summarize(choice).iterated?.should be_true
    end

    it "an unresolved call adds ExecutesCode at Error, irreversible" do
      resolved = leaf(Set{Effect::DeletesFiles}, Severity::Warning)
      unresolved = RiskUnresolved.new("dynamic_call", 1)
      summary = RiskAggregator.summarize(RiskSequence.new([resolved, unresolved] of RiskNode, 1))
      summary.effects.should eq Set{Effect::DeletesFiles, Effect::ExecutesCode}
      summary.severity.should eq Severity::Error
      summary.reversible.should eq Reversibility::No
    end

    it "nested Choice inside Sequence composes correctly" do
      pre = pure_leaf("setup")
      inner_choice = RiskChoice.new(
        [leaf(Set{Effect::NetworkEgress}, Severity::Warning), leaf(Set{Effect::ExecutesCode}, Severity::Error)] of RiskNode,
        "case", 1
      )
      seq = RiskSequence.new([pre, inner_choice] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.severity.should eq Severity::Error
      summary.effects.should eq Set{Effect::NetworkEgress, Effect::ExecutesCode}
    end
  end

  describe "RiskAggregator.all_findings" do
    it "a single leaf yields one finding" do
      findings = RiskAggregator.all_findings(leaf(Set{Effect::ReadsFiles}, Severity::Info, desc: "read_config"))
      findings.size.should eq 1
      findings.first.description.should eq "read_config"
      findings.first.iterated?.should be_false
      findings.first.branch_path.should be_empty
    end

    it "a Sequence returns findings for every child, not just the worst" do
      a = leaf(Set{Effect::ReadsFiles}, Severity::Info, desc: "read_a")
      b = leaf(Set{Effect::DeletesFiles}, Severity::Error, Reversibility::No, desc: "delete_b")
      seq = RiskSequence.new([a, b] of RiskNode, 1)
      findings = RiskAggregator.all_findings(seq)
      findings.map(&.description).should eq ["read_a", "delete_b"]
    end

    it "a Choice returns findings for EVERY branch, not just the worst" do
      safe = leaf(Set{Effect::ReadsFiles}, Severity::Info, desc: "read_a")
      dangerous = leaf(Set{Effect::DeletesFiles}, Severity::Error, Reversibility::No, desc: "delete_b")
      choice = RiskChoice.new([safe, dangerous] of RiskNode, "if", 1)
      findings = RiskAggregator.all_findings(choice)
      findings.map(&.description).should eq ["read_a", "delete_b"]
    end

    it "findings under a Choice carry the branch's origin in branch_path" do
      choice = RiskChoice.new([leaf(Set{Effect::DeletesFiles}, Severity::Error, desc: "delete_it")] of RiskNode, "if", 1)
      findings = RiskAggregator.all_findings(choice)
      findings.first.branch_path.should eq ["if branch"]
    end

    it "findings under an iterated Sequence are marked iterated" do
      seq = RiskSequence.new([leaf(Set{Effect::WritesFiles}, Severity::Warning, desc: "write_it")] of RiskNode, 1, iterated: true)
      findings = RiskAggregator.all_findings(seq)
      findings.first.iterated?.should be_true
    end

    it "an unresolved call appears as a finding with ExecutesCode/Error" do
      seq = RiskSequence.new([RiskUnresolved.new("dynamic_call", 1)] of RiskNode, 1)
      findings = RiskAggregator.all_findings(seq)
      findings.first.profile.effects.should eq Set{Effect::ExecutesCode}
      findings.first.profile.severity.should eq Severity::Error
    end

    it "an unresolved call's finding says so in its description" do
      findings = RiskAggregator.all_findings(RiskUnresolved.new("dynamic_call", 1))
      findings.map(&.description).should eq ["unresolved call: dynamic_call"]
    end

    it "nested Choice branch_path accumulates outer-to-inner" do
      inner = RiskChoice.new([leaf(Set{Effect::NetworkEgress}, Severity::Warning, desc: "fetch")] of RiskNode, "case", 1)
      outer = RiskChoice.new([inner] of RiskNode, "if", 1)
      findings = RiskAggregator.all_findings(outer)
      findings.first.branch_path.should eq ["if branch", "case branch"]
    end

    it "an empty tree yields no findings" do
      RiskAggregator.all_findings(RiskSequence.new([] of RiskNode, 1)).should be_empty
    end

    # Piece D (SCOPE.md): a lambda handed to a callee as an argument —
    # whether the callee actually invokes it isn't confirmed, so its
    # risk is wrapped RiskDeferred rather than folded in unconditionally
    # the way a RiskSequence child or RiskChoice branch would be.
    describe "RiskDeferred" do
      it "summarize uses the child's full severity/reversibility/effects as-is — deferred does not soften it" do
        risky = leaf(Set{Effect::DeletesFiles}, Severity::Error, Reversibility::No, desc: "delete_all")
        deferred = RiskDeferred.new(risky, "lambda literal passed as argument", 1)
        summary = RiskAggregator.summarize(deferred)
        summary.effects.should eq Set{Effect::DeletesFiles}
        summary.severity.should eq Severity::Error
        summary.reversible.should eq Reversibility::No
      end

      it "all_findings still surfaces the child's finding, at full severity" do
        risky = leaf(Set{Effect::DeletesFiles}, Severity::Error, desc: "delete_all")
        deferred = RiskDeferred.new(risky, "lambda literal passed as argument", 1)
        findings = RiskAggregator.all_findings(deferred)
        findings.map(&.description).should eq ["delete_all"]
        findings.first.profile.severity.should eq Severity::Error
      end

      it "all_findings' branch_path carries the deferred reason, distinguishing it from a Choice branch" do
        risky = leaf(Set{Effect::DeletesFiles}, Severity::Error, desc: "delete_all")
        deferred = RiskDeferred.new(risky, "lambda literal passed as argument", 1)
        findings = RiskAggregator.all_findings(deferred)
        findings.first.branch_path.should eq ["deferred: lambda literal passed as argument"]
      end

      it "a pure (risk-free) deferred lambda still summarizes to none-equivalent" do
        deferred = RiskDeferred.new(pure_leaf, "lambda literal passed as argument", 1)
        summary = RiskAggregator.summarize(deferred)
        summary.effects.should be_empty
        summary.severity.should eq Severity::Info
      end

      it "nested inside a Sequence alongside a confirmed risk, the Sequence still unions both" do
        # The call site itself (e.g. the argument-passing call) may
        # have its own confirmed risk, walked as an ordinary Sequence
        # child, alongside the deferred lambda passed to it — both
        # should still be visible together.
        confirmed = leaf(Set{Effect::NetworkEgress}, Severity::Warning, desc: "http_post")
        risky = leaf(Set{Effect::DeletesFiles}, Severity::Error, desc: "delete_all")
        deferred = RiskDeferred.new(risky, "lambda literal passed as argument", 1)
        seq = RiskSequence.new([confirmed, deferred] of RiskNode, 1)
        summary = RiskAggregator.summarize(seq)
        summary.effects.should eq Set{Effect::NetworkEgress, Effect::DeletesFiles}
        summary.severity.should eq Severity::Error # the deferred child is still the worst case
      end
    end
  end
end
