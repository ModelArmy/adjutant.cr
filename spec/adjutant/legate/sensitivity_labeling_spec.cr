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
  # Fixes a real gap this session's audit found: every Legate
  # read-grant verb correctly GATES a sensitive read against
  # RiskFlowPolicy (already covered elsewhere — broker_spec.cr), but
  # until now the resolved sensitivity was discarded once that gate
  # passed, so the DATA handed back carried no taint at all. This
  # file is the actual end-to-end proof the fix works: a REAL
  # `RiskFlowPolicy` with a real sensitivity pattern, a REAL verb call
  # through `interp.eval`/`make_interp` (not the `.build`-from-Crystal
  # shortcut `risk_flow_propagation_spec.cr` uses for the value TYPES'
  # own propagation, which is a different, already-solid axis — see
  # that file's own comment on why it stops at `.build`).
  #
  # `policy`/`sensitive_file`/`plain_file` are shared shape across
  # every `it`, not shared STATE — each spec builds its own tmpdir and
  # its own `make_interp` call, matching the isolation every other
  # verb spec in this codebase already follows.
  private def self.policy_for(sensitive_path : String, action : RiskFlowAction) : RiskFlowPolicy
    priority = 10
    RiskFlowPolicy.new(
      sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::File, sensitive_path, priority, Sensitivity::High),
      ],
      risk_flow_rules: [RiskFlowRule.new(RiskTag::ReadsFiles, Sensitivity::High, action)],
    )
  end

  describe "Legate read-grant verbs label content from a sensitive path" do
    it "Legate.stat: labels the returned Stat with a File/High tag matching the path" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)

        result = interp.eval(%(Legate.stat(#{file.inspect})))
        label = result.label.not_nil!
        tag = label.tags.find! { |t| t.kind.file? }
        tag.origin.should eq file
        tag.sensitivity.should eq Sensitivity::High
      end
    end

    it "Legate.read: labels the returned String" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)

        result = interp.eval(%(Legate.read(#{file.inspect})))
        result.label.should_not be_nil
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "Legate.list: labels the returned Array (fixed-prefix directory is the sensitive origin)" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        # `Legate.list`'s single broker call checks the pattern's
        # FIXED PREFIX (`dir` itself here, not the individual match) —
        # see list.cr's own comment — so the sensitivity pattern has
        # to match the directory, not the matched file, for this
        # verb's real call shape.
        #
        # `::Path.new(dir).to_posix.to_s`, not bare `dir` — list.cr
        # normalizes its pattern to `/`-separators (`Path#to_posix`)
        # BEFORE computing `fixed_prefix` (its own Windows-portability
        # fix, list.cr's own comment), so the string it actually checks
        # sensitivity against is the POSIX form. On Linux/macOS `dir`
        # already uses `/`, so this was a no-op there — a real
        # Windows-only mismatch this exact-match pattern needs the
        # same normalization to catch, caught by a Windows CI runner,
        # not by inspection.
        policy = policy_for(::Path.new(dir).to_posix.to_s, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)

        result = interp.eval(%(Legate.list(#{File.join(dir, "*.txt").inspect})))
        result.label.should_not be_nil
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "Legate.bytes: labels each yielded Chunk" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)

        result = interp.eval(%(Legate.bytes(#{file.inspect}).to_a.first))
        result.label.should_not be_nil
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "Legate.lines: labels each yielded line" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh\n")
        policy = policy_for(file, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)

        result = interp.eval(%(Legate.lines(#{file.inspect}).to_a.first))
        result.label.should_not be_nil
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "Legate.records (jsonl): labels each yielded record" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.jsonl")
        File.write(file, %({"a":1}\n))
        policy = policy_for(file, RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)

        result = interp.eval(%(Legate.records(#{file.inspect}, format: :jsonl).to_a.first[:a]))
        result.label.should_not be_nil
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "does NOT label content from a path the policy has no opinion on (no over-tainting)" do
      with_tmpdir do |dir|
        file = File.join(dir, "plain.txt")
        File.write(file, "hello")
        # A real (non-reject_all) policy whose sensitivity_patterns
        # simply don't match this path — `sensitivity_for` falls back
        # to `Sensitivity::None` (risk_flow_policy.cr's own documented
        # "no match at all -> Sensitivity::None"), so
        # `declare_sensitivity` returns `nil`, and the join with the
        # path argument's own (also nil) label stays nil.
        policy = policy_for(File.join(dir, "other-file-entirely.txt"), RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)

        interp.eval(%(Legate.read(#{file.inspect}))).label.should be_nil
      end
    end

    it "joins the file's own sensitivity with an already-tainted path argument, rather than overwriting it" do
      with_tmpdir do |dir|
        file = File.join(dir, "plain.txt")
        File.write(file, "hello")
        # Policy has NO opinion on `file` itself (see the test above)
        # — any label on the result here can only have come from the
        # PATH ARGUMENT'S own pre-existing taint, proving `join`
        # preserved it rather than the fix accidentally clobbering the
        # pre-existing "inherit the path's own label" behavior every
        # verb already had before this session's change.
        policy = policy_for(File.join(dir, "other-file-entirely.txt"), RiskFlowAction::Allow)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy)
        interp.define_native("tainted_path") do |args|
          Value.string(args.first.as_string, RiskFlowLabel.of(ProvenanceKind::UserInput, "cli-arg", Sensitivity::Elevated))
        end

        result = interp.eval(%(Legate.read(tainted_path(#{file.inspect}))))
        result.label.should_not be_nil
        result.label.not_nil!.tags.find! { |t| t.kind.user_input? }.origin.should eq "cli-arg"
      end
    end

    it "an Ask resolved to Allow still labels the result the same as a direct Allow" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskFlowAction::Ask)
        callback = ->(req : RiskFlowDecisionRequest) : RiskFlowDecision { RiskFlowDecision::Allow }
        interp, _ = make_interp(
          grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy, on_risk_flow_decision: callback,
        )

        result = interp.eval(%(Legate.read(#{file.inspect})))
        result.label.should_not be_nil
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    it "an Ask resolved to Reject raises RiskFlowRejectedError and returns nothing to label" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        policy = policy_for(file, RiskFlowAction::Ask)
        callback = ->(req : RiskFlowDecisionRequest) : RiskFlowDecision { RiskFlowDecision::Reject }
        interp, _ = make_interp(
          grants: Legate::Grants.new(read_roots: [dir]), risk_flow_policy: policy, on_risk_flow_decision: callback,
        )

        eval = interp.eval(<<-RUBY)
        begin
          Legate.read(#{file.inspect})
          "no error"
        rescue RiskFlowRejectedError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end
  end
end
