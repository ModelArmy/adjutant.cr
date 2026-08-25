require "../../spec_helper"
require "file_utils"

# Crystal's stdlib has no Dir.mktmpdir (that's a Ruby-ism) — this
# hand-rolls the same shape: a fresh, uniquely-named directory under
# the system temp dir, yielded to the block, and recursively removed
# afterward regardless of how the block exits. Local to this spec
# file rather than spec_helper.cr since no other spec needs it yet;
# worth promoting there if a second spec file wants the same thing.
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
  describe Legate::Grants do
    describe "#check_root" do
      it "denies when no roots are granted" do
        grants = Legate::Grants.deny_all
        decision = grants.check_root(__FILE__, [] of String)
        decision.allowed?.should be_false
        decision.reason.should match(/no roots granted/)
      end

      it "allows a path exactly at a granted root" do
        with_tmpdir do |dir|
          grants = Legate::Grants.new(read_roots: [dir])
          grants.check_root(dir, [dir]).allowed?.should be_true
        end
      end

      it "allows a path nested under a granted root" do
        with_tmpdir do |dir|
          nested = File.join(dir, "logs", "app.log")
          Dir.mkdir(File.join(dir, "logs"))
          File.write(nested, "hi")
          Legate::Grants.new.check_root(nested, [dir]).allowed?.should be_true
        end
      end

      it "denies a sibling directory that merely shares a string prefix" do
        with_tmpdir do |dir|
          # "/work/input-2" should NOT count as under "/work/input"
          root = File.join(dir, "input")
          sibling = File.join(dir, "input-2")
          Dir.mkdir(root)
          Dir.mkdir(sibling)
          Legate::Grants.new.check_root(sibling, [root]).allowed?.should be_false
        end
      end

      it "denies a path outside every granted root" do
        with_tmpdir do |dir|
          with_tmpdir do |other|
            Legate::Grants.new.check_root(other, [dir]).allowed?.should be_false
          end
        end
      end

      it "denies a path that does not exist" do
        with_tmpdir do |dir|
          decision = Legate::Grants.new.check_root(File.join(dir, "nope"), [dir])
          decision.allowed?.should be_false
          decision.reason.should match(/does not exist/)
        end
      end

      it "resolves a symlinked root and a symlinked path to the same target" do
        with_tmpdir do |dir|
          real_root = File.join(dir, "real_root")
          Dir.mkdir(real_root)
          file = File.join(real_root, "f.txt")
          File.write(file, "hi")

          linked_root = File.join(dir, "linked_root")
          File.symlink(real_root, linked_root)
          linked_file = File.join(linked_root, "f.txt")

          Legate::Grants.new.check_root(linked_file, [real_root]).allowed?.should be_true
        end
      end
    end

    describe "#check_host" do
      it "denies when no hosts are granted" do
        Legate::Grants.deny_all.check_host("api.example.com").allowed?.should be_false
      end

      it "allows an exact allowlisted host" do
        grants = Legate::Grants.new(net_hosts: ["api.example.com"])
        grants.check_host("api.example.com").allowed?.should be_true
      end

      it "denies a host not on the allowlist" do
        grants = Legate::Grants.new(net_hosts: ["api.example.com"])
        grants.check_host("evil.example.com").allowed?.should be_false
      end

      it "does not treat a subdomain as matching its parent" do
        grants = Legate::Grants.new(net_hosts: ["example.com"])
        grants.check_host("evil.example.com").allowed?.should be_false
      end
    end

    describe "#check_binary" do
      it "denies when no binaries are granted" do
        Legate::Grants.deny_all.check_binary("/bin/ls").allowed?.should be_false
      end

      it "allows an exact allowlisted absolute path" do
        with_tmpdir do |dir|
          bin = File.join(dir, "mytool")
          File.write(bin, "#!/bin/sh\n")
          File.chmod(bin, 0o755)
          Legate::Grants.new(exec_binaries: [bin]).check_binary(bin).allowed?.should be_true
        end
      end

      it "denies a binary not on the allowlist" do
        with_tmpdir do |dir|
          allowed = File.join(dir, "good")
          other = File.join(dir, "bad")
          [allowed, other].each do |bin|
            File.write(bin, "#!/bin/sh\n")
            File.chmod(bin, 0o755)
          end
          Legate::Grants.new(exec_binaries: [allowed]).check_binary(other).allowed?.should be_false
        end
      end

      it "resolves a PATH-searched bare command name before comparing" do
        with_tmpdir do |dir|
          bin = File.join(dir, "mytool")
          File.write(bin, "#!/bin/sh\n")
          File.chmod(bin, 0o755)

          original_path = ENV["PATH"]?
          ENV["PATH"] = "#{dir}:#{original_path}"
          begin
            Legate::Grants.new(exec_binaries: [bin]).check_binary("mytool").allowed?.should be_true
          ensure
            ENV["PATH"] = original_path
          end
        end
      end

      it "denies a bare command name not found on PATH" do
        Legate::Grants.new(exec_binaries: ["/bin/ls"]).check_binary("definitely-not-a-real-command-xyz").allowed?.should be_false
      end
    end
  end
end
