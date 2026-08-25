require "../../../spec_helper"
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
  describe "Legate.stat" do
    it "returns a Stat with the right type/size for a real file" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        s = Legate.stat(#{(file).inspect})
        [s.type, s.size, s.file?, s.dir?]
        RUBY
        arr = eval.as_array.to_a
        arr[0].as_sym.name.should eq "file"
        arr[1].as_int.should eq 5
        arr[2].as_bool.should eq true
        arr[3].as_bool.should eq false
      end
    end

    it "returns a Stat with type :dir for a directory" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.stat(#{(dir).inspect}).type)).as_sym.name.should eq "dir"
      end
    end

    it "returns nil for a non-existent path that IS under a granted root" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.stat(#{(File.join(dir, "nope.txt")).inspect}))).raw.nil?.should be_true
      end
    end

    it "raises FatalSignal (denied), not nil, for a non-existent path OUTSIDE every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.stat(#{(File.join(other, "nope.txt")).inspect})))
          end
        end
      end
    end

    it "raises FatalSignal for an EXISTING path outside every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          file = File.join(other, "f.txt")
          File.write(file, "hello")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.stat(#{(file).inspect})))
          end
        end
      end
    end

    it "reports :symlink for a symlink, without following it" do
      with_tmpdir do |dir|
        target = File.join(dir, "target.txt")
        File.write(target, "hello")
        link = File.join(dir, "link.txt")
        File.symlink(target, link)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.stat(#{(link).inspect}).type)).as_sym.name.should eq "symlink"
      end
    end

    it "denies with no roots granted at all" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello")
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.stat(#{(file).inspect})))
        end
      end
    end

    it "accepts a Legate::Path argument identically to a String" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.stat(Legate::Path.new(#{(file).inspect})).size)).as_int.should eq 5
      end
    end

    it "logs an :allowed audit record on success" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.stat(#{(file).inspect})))
        record = interp.broker.audit_log.records.last
        record.verb.should eq "read"
        record.grant.should eq :read
        record.decision.should eq :allowed
      end
    end
  end

  describe "Legate::Grants#check_root_maybe_missing" do
    it "denies when no roots are granted" do
      Legate::Grants.deny_all.check_root_maybe_missing("/tmp/whatever", [] of String).allowed?.should be_false
    end

    it "allows a non-existent leaf whose parent directory is under a granted root" do
      with_tmpdir do |dir|
        decision = Legate::Grants.new.check_root_maybe_missing(File.join(dir, "nope.txt"), [dir])
        decision.allowed?.should be_true
      end
    end

    it "allows several levels of non-existent nesting under a granted root" do
      with_tmpdir do |dir|
        decision = Legate::Grants.new.check_root_maybe_missing(File.join(dir, "a", "b", "c.txt"), [dir])
        decision.allowed?.should be_true
      end
    end

    it "denies a non-existent leaf whose parent is outside every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          decision = Legate::Grants.new.check_root_maybe_missing(File.join(other, "nope.txt"), [dir])
          decision.allowed?.should be_false
        end
      end
    end

    it "still allows an EXISTING path under a granted root, same as check_root" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        Legate::Grants.new.check_root_maybe_missing(file, [dir]).allowed?.should be_true
      end
    end
  end
end
