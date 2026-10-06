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
  # Two regexes matching one file at the same priority: a tie only a
  # real subject reveals, whatever is caught when the policy is built.
  private def self.tied_sensitivity : RiskFlowPolicy
    RiskFlowPolicy.new(
      sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::File, "secret", 10, Sensitivity::High, PatternType::Regex),
        SensitivityPattern.new(ProvenanceKind::File, "\\.txt$", 10, Sensitivity::Elevated, PatternType::Regex),
      ],
      risk_flow_rules: allow_unlisted,
    )
  end

  # A tie is the host's configuration error (H003), so it ends the run
  # however the script tries to rescue it.
  describe "A risk-flow policy tie reached mid-run" do
    it "passes a sensitivity tie past `rescue => e`" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        interp, _ = make_interp(risk_flow_policy: tied_sensitivity, grants: Legate::Grants.new(read_roots: [dir]))

        expect_raises(AmbiguousRiskFlowPolicyError) do
          interp.eval(<<-RUBY)
            begin
              Legate.read(#{file.inspect})
            rescue => e
              "rescued \#{e.class}"
            end
          RUBY
        end
      end
    end

    it "passes a sensitivity tie past `rescue Exception`" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        interp, _ = make_interp(risk_flow_policy: tied_sensitivity, grants: Legate::Grants.new(read_roots: [dir]))

        expect_raises(AmbiguousRiskFlowPolicyError) do
          interp.eval(<<-RUBY)
            begin
              Legate.read(#{file.inspect})
            rescue Exception => e
              "rescued \#{e.class}"
            end
          RUBY
        end
      end
    end

    # The call is nested in a block a native method runs, so every
    # `call_native` on the way out must let the tie through.
    it "passes a tie reached inside a block past the rescue around it" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "shh")
        interp, _ = make_interp(risk_flow_policy: tied_sensitivity, grants: Legate::Grants.new(read_roots: [dir]))

        expect_raises(AmbiguousRiskFlowPolicyError) do
          interp.eval(<<-RUBY)
            begin
              [#{file.inspect}].map { |path| Legate.read(path) }
            rescue => e
              "rescued \#{e.class}"
            end
          RUBY
        end
      end
    end

    it "passes a tie between exceptions past `rescue => e`" do
      with_tmpdir do |dir|
        file = File.join(dir, "notes.txt")
        File.write(file, "hi")
        cli_arg = RiskFlowOrigin.new(ProvenanceKind::UserInput, "cli-arg")
        policy = RiskFlowPolicy.new(
          risk_flow_rules: allow_unlisted([
            RiskFlowRule.new(Authority::Read, Sensitivity::Elevated, RiskFlowAction::Reject),
            RiskFlowRule.new(Authority::Read, Sensitivity::Elevated, RiskFlowAction::Allow,
              origin: cli_arg, subject: RiskFlowSubject.new("notes", PatternType::Regex), priority: 10),
            RiskFlowRule.new(Authority::Read, Sensitivity::Elevated, RiskFlowAction::Reject,
              origin: cli_arg, subject: RiskFlowSubject.new("\\.txt$", PatternType::Regex), priority: 10),
          ]),
        )
        interp, _ = make_interp(risk_flow_policy: policy, grants: Legate::Grants.new(read_roots: [dir]))
        interp.define_native("tainted_path") do |args|
          Value.string(args.first.as_string, RiskFlowLabel.of(ProvenanceKind::UserInput, "cli-arg", Sensitivity::Elevated))
        end

        expect_raises(AmbiguousRiskFlowPolicyError) do
          interp.eval(<<-RUBY)
            begin
              Legate.read(tainted_path(#{file.inspect}))
            rescue => e
              "rescued \#{e.class}"
            end
          RUBY
        end
      end
    end
  end
end
