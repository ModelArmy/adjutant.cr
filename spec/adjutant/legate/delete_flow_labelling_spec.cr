require "../../spec_helper"
require "file_utils"

private def with_tmpdir(&)
  path = File.join(Dir.tempdir, "adjutant-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

module Adjutant
  # The delete grant's half of `sensitivity_labeling_spec.cr` — same
  # end-to-end shape (a REAL `RiskFlowPolicy`, a REAL verb call
  # through `interp.eval`, not a `.build`-from-Crystal shortcut), but
  # exercising the two axes the read/write verbs never could:
  #
  #   1. `Legate.rm`'s return value is a COUNT, not content. It is
  #      labelled anyway — see `rm.cr`'s own comment for why a count
  #      derived from a sensitive path is still a channel worth
  #      tainting. This file is the proof that labelling actually
  #      happens rather than being an aspiration in a comment.
  #   2. `Legate.mv` makes TWO authorize calls, so it has TWO
  #      independent points at which policy can reject. A rule keyed
  #      on `DeletesFiles` and a rule keyed on `WritesFiles` must each
  #      be able to stop the move on their own, and in both cases the
  #      source must survive intact — a move rejected halfway would be
  #      the worst possible outcome, and the ordering in `mv.cr`
  #      (authorize both, THEN touch the filesystem) is what prevents
  #      it. Both are asserted below.
  private def self.policy_for(sensitive_path : String, tag : RiskTag, action : RiskFlowAction) : RiskFlowPolicy
    priority = 10
    RiskFlowPolicy.new(
      sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::File, sensitive_path, priority, Sensitivity::High),
      ],
      risk_flow_rules: [RiskFlowRule.new(tag, Sensitivity::High, action)],
    )
  end

  private def self.delete_grants(dir : String) : Legate::Grants
    Legate::Grants.new(delete_roots: [dir], write_roots: [dir])
  end

  describe "Legate delete-grant verbs and information flow control" do
    it "Legate.rm: labels the returned count with the target's resolved sensitivity" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskTag::DeletesFiles, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        result = interp.eval(%(Legate.rm(#{file.inspect})))
        result.as_int.should eq 1
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        tag = label.tags.find! { |t| t.kind.file? }
        tag.origin.should eq file
      end
    end

    # The `0` path returns just as early as it can and still has to
    # carry the label — a count of zero from a sensitive path is
    # itself information about that path (it isn't there), and the
    # early `next` in `rm.cr` is exactly the sort of place a label
    # gets dropped by accident.
    it "Legate.rm: labels the count even on the missing-path 0 return" do
      with_tmpdir do |dir|
        missing = File.join(dir, "gone.txt")
        policy = policy_for(missing, RiskTag::DeletesFiles, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        result = interp.eval(%(Legate.rm(#{missing.inspect})))
        result.as_int.should eq 0
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "Legate.rm: labels the count on the recursive-directory path too" do
      with_tmpdir do |dir|
        target = File.join(dir, "tree")
        Dir.mkdir(target)
        File.write(File.join(target, "a.txt"), "a")
        policy = policy_for(target, RiskTag::DeletesFiles, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        result = interp.eval(%(Legate.rm(#{target.inspect}, recursive: true)))
        result.as_int.should eq 2
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    # The one that actually matters for a destructive verb: a Reject
    # must stop the deletion, not merely taint its result. The file
    # surviving is the whole assertion.
    it "Legate.rm: a Reject leaves the target on disk" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskTag::DeletesFiles, RiskFlowAction::Reject)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        eval = interp.eval(<<-RUBY)
        begin
          Legate.rm(#{file.inspect})
          "no error"
        rescue RiskFlowRejectedError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.exists?(file).should be_true
      end
    end

    it "Legate.rm: an Ask resolved to Reject also leaves the target on disk" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskTag::DeletesFiles, RiskFlowAction::Ask)
        callback = ->(req : RiskFlowDecisionRequest) : RiskFlowDecision { RiskFlowDecision::Reject }
        interp, _ = make_interp(
          grants: delete_grants(dir), risk_flow_policy: policy, on_risk_flow_decision: callback,
        )

        eval = interp.eval(<<-RUBY)
        begin
          Legate.rm(#{file.inspect})
          "no error"
        rescue RiskFlowRejectedError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.exists?(file).should be_true
      end
    end

    it "Legate.rm: an Ask resolved to Allow deletes and labels exactly as a direct Allow would" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskTag::DeletesFiles, RiskFlowAction::Ask)
        callback = ->(req : RiskFlowDecisionRequest) : RiskFlowDecision { RiskFlowDecision::Allow }
        interp, _ = make_interp(
          grants: delete_grants(dir), risk_flow_policy: policy, on_risk_flow_decision: callback,
        )

        result = interp.eval(%(Legate.rm(#{file.inspect})))
        result.as_int.should eq 1
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
        File.exists?(file).should be_false
      end
    end

    it "Legate.mv: labels the returned Path with the SOURCE's resolved sensitivity" do
      with_tmpdir do |dir|
        from = File.join(dir, "secret.txt")
        to = File.join(dir, "moved.txt")
        File.write(from, "shh")
        policy = policy_for(from, RiskTag::DeletesFiles, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        result = interp.eval(%(Legate.mv(#{from.inspect}, #{to.inspect})))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    # The other half of the join. `mv.cr` combines the labels from
    # BOTH authorize calls, so a sensitive DESTINATION taints the
    # result even when the source is entirely mundane — the case a
    # source-only implementation would silently get wrong.
    it "Legate.mv: labels the returned Path with the DESTINATION's resolved sensitivity too" do
      with_tmpdir do |dir|
        from = File.join(dir, "plain.txt")
        to = File.join(dir, "secret.txt")
        File.write(from, "hi")
        policy = policy_for(to, RiskTag::WritesFiles, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        result = interp.eval(%(Legate.mv(#{from.inspect}, #{to.inspect})))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "Legate.mv: a Reject on the DELETE side leaves the source untouched and creates no destination" do
      with_tmpdir do |dir|
        from = File.join(dir, "secret.txt")
        to = File.join(dir, "moved.txt")
        File.write(from, "shh")
        policy = policy_for(from, RiskTag::DeletesFiles, RiskFlowAction::Reject)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        eval = interp.eval(<<-RUBY)
        begin
          Legate.mv(#{from.inspect}, #{to.inspect})
          "no error"
        rescue RiskFlowRejectedError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(from).should eq "shh"
        File.exists?(to).should be_false
      end
    end

    # The asymmetric one, and the reason this file exists at all: the
    # source is entirely unremarkable, and policy objects only to the
    # DESTINATION. A `mv` gated on its delete side alone would sail
    # straight past this and relocate the file anyway.
    it "Legate.mv: a Reject on the WRITE side also leaves the source untouched" do
      with_tmpdir do |dir|
        from = File.join(dir, "plain.txt")
        to = File.join(dir, "secret.txt")
        File.write(from, "hi")
        policy = policy_for(to, RiskTag::WritesFiles, RiskFlowAction::Reject)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        eval = interp.eval(<<-RUBY)
        begin
          Legate.mv(#{from.inspect}, #{to.inspect})
          "no error"
        rescue RiskFlowRejectedError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(from).should eq "hi"
        File.exists?(to).should be_false
      end
    end

    # A rejected verb must not leave a half-finished audit trail
    # either — `mv`'s delete authorization is logged as :allowed
    # before the write authorization is even attempted, and the write
    # one is logged as :rejected. Both records, one of each outcome:
    # the audit log is meant to record what was ATTEMPTED, not just
    # what succeeded.
    it "Legate.mv: a Reject on the write side still records both authorize attempts" do
      with_tmpdir do |dir|
        from = File.join(dir, "plain.txt")
        to = File.join(dir, "secret.txt")
        File.write(from, "hi")
        policy = policy_for(to, RiskTag::WritesFiles, RiskFlowAction::Reject)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        interp.eval(<<-RUBY)
        begin
          Legate.mv(#{from.inspect}, #{to.inspect})
        rescue RiskFlowRejectedError
        end
        RUBY

        records = interp.broker.audit_log.records
        deletes = records.select { |r| r.verb == "delete" }
        writes = records.select { |r| r.verb == "write" }
        deletes.size.should eq 1
        deletes.first.decision.should eq :allowed
        writes.size.should eq 1
        writes.first.decision.should eq :rejected
      end
    end

    # Taint flows onward from a delete-grant verb the same way it does
    # from a read-grant one — the labelled `Legate::Path` `mv` returns
    # carries its sensitivity into whatever the script derives from
    # it, rather than the label dying at the verb boundary.
    it "Legate.mv: the returned Path's label propagates into a derived String" do
      with_tmpdir do |dir|
        from = File.join(dir, "secret.txt")
        to = File.join(dir, "moved.txt")
        File.write(from, "shh")
        policy = policy_for(from, RiskTag::DeletesFiles, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: delete_grants(dir), risk_flow_policy: policy)

        result = interp.eval(%(Legate.mv(#{from.inspect}, #{to.inspect}).basename))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end
  end
end
