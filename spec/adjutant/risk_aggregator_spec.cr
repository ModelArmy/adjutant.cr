require "../spec_helper"

module Adjutant
  private def self.leaf(tags : Set(RiskTag), severity : Severity, reversible : Reversibility = Reversibility::Yes,
                        note : String? = nil, desc = "call")
    RiskLeaf.new(RiskProfile.new(tags: tags, reversible: reversible, severity: severity, note: note), desc, 1)
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
      summary.tags.should be_empty
      summary.severity.should eq Severity::Info
    end

    it "a Sequence unions tags across all children (all occur)" do
      a = leaf(Set{RiskTag::ReadsFiles}, Severity::Info)
      b = leaf(Set{RiskTag::NetworkEgress}, Severity::Warning)
      seq = RiskSequence.new([a, b] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.tags.should eq Set{RiskTag::ReadsFiles, RiskTag::NetworkEgress}
      summary.severity.should eq Severity::Warning
    end

    it "a Sequence's severity/reversibility reflect the worst single child, not an average" do
      safe = leaf(Set{RiskTag::ReadsFiles}, Severity::Info)
      dangerous = leaf(Set{RiskTag::DeletesFiles}, Severity::Error, Reversibility::No)
      seq = RiskSequence.new([safe, dangerous] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.severity.should eq Severity::Error
      summary.reversible.should eq Reversibility::No
    end

    it "an iterated Sequence marks the summary as iterated" do
      seq = RiskSequence.new([leaf(Set{RiskTag::WritesFiles}, Severity::Warning)] of RiskNode, 1, iterated: true)
      RiskAggregator.summarize(seq).iterated?.should be_true
    end

    it "a Choice takes the single worst branch, not a union of both" do
      read_branch = leaf(Set{RiskTag::ReadsFiles}, Severity::Info)
      delete_branch = leaf(Set{RiskTag::DeletesFiles}, Severity::Error, Reversibility::No)
      choice = RiskChoice.new([read_branch, delete_branch] of RiskNode, "if", 1)
      summary = RiskAggregator.summarize(choice)
      # Only the worst branch's tags appear — NOT the union of both
      # branches, since only one branch can execute in a given run.
      summary.tags.should eq Set{RiskTag::DeletesFiles}
      summary.severity.should eq Severity::Error
    end

    it "a Choice's path records which branch caused the worst case" do
      read_branch = leaf(Set{RiskTag::ReadsFiles}, Severity::Info, desc: "read_config")
      delete_branch = leaf(Set{RiskTag::DeletesFiles}, Severity::Error, Reversibility::No, desc: "delete_all")
      choice = RiskChoice.new([read_branch, delete_branch] of RiskNode, "if", 1)
      summary = RiskAggregator.summarize(choice)
      summary.path.should eq ["if branch", "delete_all"]
    end

    it "RiskUnresolved always outranks any resolved leaf" do
      resolved = leaf(Set{RiskTag::DeletesFiles}, Severity::Error, Reversibility::No)
      unresolved = RiskUnresolved.new("dynamic_call", 1)
      seq = RiskSequence.new([resolved, unresolved] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.path.should contain "unresolved call: dynamic_call"
    end

    it "nested Choice inside Sequence composes correctly" do
      pre = pure_leaf("setup")
      inner_choice = RiskChoice.new(
        [leaf(Set{RiskTag::NetworkEgress}, Severity::Warning), leaf(Set{RiskTag::ExecutesCode}, Severity::Error)] of RiskNode,
        "case", 1
      )
      seq = RiskSequence.new([pre, inner_choice] of RiskNode, 1)
      summary = RiskAggregator.summarize(seq)
      summary.severity.should eq Severity::Error
      summary.tags.should eq Set{RiskTag::ExecutesCode}
    end
  end

  describe "RiskAggregator.all_findings" do
    it "a single leaf yields one finding" do
      findings = RiskAggregator.all_findings(leaf(Set{RiskTag::ReadsFiles}, Severity::Info, desc: "read_config"))
      findings.size.should eq 1
      findings.first.description.should eq "read_config"
      findings.first.iterated?.should be_false
      findings.first.branch_path.should be_empty
    end

    it "a Sequence returns findings for every child, not just the worst" do
      a = leaf(Set{RiskTag::ReadsFiles}, Severity::Info, desc: "read_a")
      b = leaf(Set{RiskTag::DeletesFiles}, Severity::Error, Reversibility::No, desc: "delete_b")
      seq = RiskSequence.new([a, b] of RiskNode, 1)
      findings = RiskAggregator.all_findings(seq)
      findings.map(&.description).should eq ["read_a", "delete_b"]
    end

    it "a Choice returns findings for EVERY branch, not just the worst" do
      safe = leaf(Set{RiskTag::ReadsFiles}, Severity::Info, desc: "read_a")
      dangerous = leaf(Set{RiskTag::DeletesFiles}, Severity::Error, Reversibility::No, desc: "delete_b")
      choice = RiskChoice.new([safe, dangerous] of RiskNode, "if", 1)
      findings = RiskAggregator.all_findings(choice)
      findings.map(&.description).should eq ["read_a", "delete_b"]
    end

    it "findings under a Choice carry the branch's origin in branch_path" do
      choice = RiskChoice.new([leaf(Set{RiskTag::DeletesFiles}, Severity::Error, desc: "delete_it")] of RiskNode, "if", 1)
      findings = RiskAggregator.all_findings(choice)
      findings.first.branch_path.should eq ["if branch"]
    end

    it "findings under an iterated Sequence are marked iterated" do
      seq = RiskSequence.new([leaf(Set{RiskTag::WritesFiles}, Severity::Warning, desc: "write_it")] of RiskNode, 1, iterated: true)
      findings = RiskAggregator.all_findings(seq)
      findings.first.iterated?.should be_true
    end

    it "an unresolved call appears as a finding with ExecutesCode/Error" do
      seq = RiskSequence.new([RiskUnresolved.new("dynamic_call", 1)] of RiskNode, 1)
      findings = RiskAggregator.all_findings(seq)
      findings.first.profile.tags.should eq Set{RiskTag::ExecutesCode}
      findings.first.profile.severity.should eq Severity::Error
    end

    it "nested Choice branch_path accumulates outer-to-inner" do
      inner = RiskChoice.new([leaf(Set{RiskTag::NetworkEgress}, Severity::Warning, desc: "fetch")] of RiskNode, "case", 1)
      outer = RiskChoice.new([inner] of RiskNode, "if", 1)
      findings = RiskAggregator.all_findings(outer)
      findings.first.branch_path.should eq ["if branch", "case branch"]
    end

    it "an empty tree yields no findings" do
      RiskAggregator.all_findings(RiskSequence.new([] of RiskNode, 1)).should be_empty
    end
  end
end
