require "../../spec_helper"
require "file_utils"

# Yields a fresh directory by its real path, so that every spelling
# built from it differs from the canonical one only in what the spec
# adds.
private def with_real_tmpdir(&)
  path = File.join(Dir.tempdir, "adjutant-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(path)
  begin
    yield File.realpath(path)
  ensure
    FileUtils.rm_rf(path)
  end
end

private def reads(interp : Adjutant::Interpreter, path : String) : String
  interp.eval(%(Legate.read(#{path.inspect}))).as_string
end

module Adjutant
  # A policy judges the file a call reaches, however the script
  # spells its path; the grant already does.
  describe "Policy matching of path subjects" do
    it "applies a sensitivity pattern to every spelling of its file" do
      with_real_tmpdir do |dir|
        Dir.mkdir(File.join(dir, "sub"))
        secret = File.join(dir, "secret.txt")
        File.write(secret, "shh")
        policy = RiskFlowPolicy.new(
          sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::File, secret, 10, Sensitivity::High)],
          risk_flow_rules: allow_unlisted([RiskFlowRule.new(Authority::Read, Sensitivity::High, RiskFlowAction::Reject)]),
        )
        interp, _ = make_interp(risk_flow_policy: policy, grants: Legate::Grants.new(read_roots: [dir]))

        [
          secret,
          File.join(dir, ".", "secret.txt"),
          File.join(dir, "sub", "..", "secret.txt"),
          "#{dir}//secret.txt",
        ].each do |spelling|
          expect_raises(RuntimeError, /risk flow policy rejected/) do
            reads(interp, spelling)
          end
        end
      end
    end

    it "applies a sensitivity pattern through a symlink to its file" do
      with_real_tmpdir do |dir|
        secret = File.join(dir, "secret.txt")
        File.write(secret, "shh")
        link = File.join(dir, "notes.txt")
        File.symlink(secret, link)
        policy = RiskFlowPolicy.new(
          sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::File, secret, 10, Sensitivity::High)],
          risk_flow_rules: allow_unlisted([RiskFlowRule.new(Authority::Read, Sensitivity::High, RiskFlowAction::Reject)]),
        )
        interp, _ = make_interp(risk_flow_policy: policy, grants: Legate::Grants.new(read_roots: [dir]))

        expect_raises(RuntimeError, /risk flow policy rejected/) do
          reads(interp, link)
        end
      end
    end

    # On Windows, `File.realpath` resolves only a path's final
    # component; see SCOPE's "Windows resolves only a path's last link".
    {% if flag?(:windows) %}
      pending "applies a sensitivity pattern written through a symlinked directory (Windows realpath)" { }
    {% else %}
      # As a pattern under macOS's `/var` or `/tmp` is.
      it "applies a sensitivity pattern written through a symlinked directory" do
        with_real_tmpdir do |dir|
          real_dir = File.join(dir, "real")
          Dir.mkdir(real_dir)
          File.write(File.join(real_dir, "secret.txt"), "shh")
          alias_dir = File.join(dir, "alias")
          File.symlink(real_dir, alias_dir)
          policy = RiskFlowPolicy.new(
            sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::File, File.join(alias_dir, "secret.txt"), 10, Sensitivity::High)],
            risk_flow_rules: allow_unlisted([RiskFlowRule.new(Authority::Read, Sensitivity::High, RiskFlowAction::Reject)]),
          )
          interp, _ = make_interp(risk_flow_policy: policy, grants: Legate::Grants.new(read_roots: [dir]))

          expect_raises(RuntimeError, /risk flow policy rejected/) do
            reads(interp, File.join(real_dir, "secret.txt"))
          end
        end
      end
    {% end %}

    it "doesn't apply an exception's subject to a path that climbs out of it" do
      with_real_tmpdir do |dir|
        repo = File.join(dir, "repo")
        Dir.mkdir(repo)
        File.write(File.join(repo, "secret.txt"), "in repo")
        File.write(File.join(dir, "secret.txt"), "outside")
        policy = RiskFlowPolicy.new(
          sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::File, "secret\\.txt$", 10, Sensitivity::High, PatternType::Regex)],
          risk_flow_rules: allow_unlisted([
            RiskFlowRule.new(Authority::Read, Sensitivity::High, RiskFlowAction::Reject),
            RiskFlowRule.new(Authority::Read, Sensitivity::High, RiskFlowAction::Allow,
              subject: RiskFlowSubject.new("^#{Regex.escape(::Path.new(repo).to_posix.to_s)}/", PatternType::Regex), priority: 10),
          ]),
        )
        interp, _ = make_interp(risk_flow_policy: policy, grants: Legate::Grants.new(read_roots: [dir]))

        reads(interp, File.join(repo, "secret.txt")).should eq "in repo"
        expect_raises(RuntimeError, /risk flow policy rejected/) do
          reads(interp, File.join(repo, "..", "secret.txt"))
        end
      end
    end
  end
end
