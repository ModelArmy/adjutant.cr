require "../../../spec_helper"

module Adjutant
  describe "Legate.scratch" do
    it "returns a Path to a directory that already exists" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      dir = Legate.scratch.to_s
      Legate.stat(dir).dir? ? "dir" : "not a dir"
      RUBY
      eval.as_string.should eq "dir"
    end

    it "is writable, readable, and deletable with no write/read/delete grant at all" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      dir = Legate.scratch
      path = dir / "hello.txt"
      Legate.write(path, "hi")
      contents = Legate.read(path)
      Legate.rm(path)
      contents
      RUBY
      eval.as_string.should eq "hi"
    end

    it "returns the SAME directory for every call within one run" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(%(Legate.scratch.to_s == Legate.scratch.to_s))
      eval.truthy?.should be_true
    end

    it "does not widen access to paths OUTSIDE scratch" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
        interp.eval(%(Legate.write("/tmp/not-scratch-#{Random::Secure.hex(4)}.txt", "hi")))
      end
    end

    it "removes the directory from disk once the run (eval call) ends" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(%(Legate.scratch.to_s))
      path = eval.as_string
      File.directory?(path).should be_false
    end

    it "gives the NEXT eval call on the same Interpreter a fresh directory" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      first = interp.eval(%(Legate.scratch.to_s)).as_string
      second = interp.eval(%(Legate.scratch.to_s)).as_string
      first.should_not eq second
      File.directory?(first).should be_false
      File.directory?(second).should be_false
    end

    it "tolerates a run that never calls Legate.scratch at all (no cleanup work to do)" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      # Nothing to assert on disk here — this is really a "does not
      # raise" check that `cleanup_scratch!`'s early-exit path (no
      # `@scratch_dir` was ever created this run) is safe.
      interp.eval(%("no scratch touched"))
    end

    it "logs no audit record — ambient verbs are not authorized against, per broker.cr" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      interp.eval(%(Legate.scratch))
      interp.broker.audit_log.records.should be_empty
    end
  end
end
