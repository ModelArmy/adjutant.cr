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
  describe "Legate.write" do
    it "writes a String and returns the byte count" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(%(Legate.write(#{(file).inspect}, "hello")))
        eval.as_int.should eq 5_i64
        File.read(file).should eq "hello"
      end
    end

    it "writes an Array of Strings concatenated, in order" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(%(Legate.write(#{(file).inspect}, ["a", "b", "c"])))
        eval.as_int.should eq 3_i64
        File.read(file).should eq "abc"
      end
    end

    it "writes a Legate stream's elements without materializing them all first" do
      with_tmpdir do |dir|
        src = File.join(dir, "src.txt")
        dest = File.join(dir, "dest.txt")
        File.write(src, "alpha\nbeta\ngamma\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.write(#{(dest).inspect}, Legate.lines(#{(src).inspect}).map { |l| l.upcase + "\\n" })
        RUBY
        eval.as_int.should eq 17_i64 # "ALPHA\nBETA\nGAMMA\n"
        File.read(dest).should eq "ALPHA\nBETA\nGAMMA\n"
      end
    end

    it "creates parent directories automatically, recursively" do
      with_tmpdir do |dir|
        file = File.join(dir, "a", "b", "c", "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.write(#{(file).inspect}, "hi")))
        File.read(file).should eq "hi"
      end
    end

    it "leaves no .tmp file behind after a successful write" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.write(#{(file).inspect}, "hi")))
        Dir.children(dir).should eq ["f.txt"]
      end
    end

    it "raises Legate::Conflict when the target is an existing directory" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write(#{(target).inspect}, "hi")
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises TypeError (R037) when data is neither a String, Array, nor stream" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write(#{(file).inspect}, 42)
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises TypeError (R038) when an Array element isn't a String, and writes nothing at all" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write(#{(file).inspect}, ["a", 42, "c"])
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.exists?(file).should be_false
        Dir.children(dir).should be_empty
      end
    end
    it "raises FatalSignal on total_write budget exhaustion" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        limits = Legate::Limits.new(total_write: 3_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir], limits: limits))
        expect_raises(Legate::FatalSignal) do
          interp.eval(%(Legate.write(#{(file).inspect}, "this is way more than 3 bytes")))
        end
      end
    end

    it "denies with a FatalSignal for a path outside every granted write root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
            interp.eval(%(Legate.write(#{(File.join(other, "f.txt")).inspect}, "hi")))
          end
        end
      end
    end

    it "denies with no write grant at all" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
          interp.eval(%(Legate.write(#{(File.join(dir, "f.txt")).inspect}, "hi")))
        end
      end
    end

    it "logs exactly one :allowed audit record per invocation" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.write(#{(file).inspect}, "hi")))
        records = interp.broker.audit_log.records.select { |r| r.verb == "write" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    # The destination rule. `write` refuses; `write!` replaces. These
    # are the tests that would have caught the original silent
    # clobber, and they are deliberately paired: each verb is checked
    # both for the refusal/replacement itself AND for what happens to
    # the previous content, because "raises" without "and the file is
    # still there" would pass against a verb that destroyed the target
    # and then complained.
    it "raises Legate::Conflict when the target file already exists" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write(#{(file).inspect}, "new")
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(file).should eq "original"
      end
    end

    it "names Legate.write! in the Conflict message, per principle 6" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write(#{(file).inspect}, "new")
          "no error"
        rescue Legate::Conflict => e
          e.message
        end
        RUBY
        eval.as_string.should contain "Legate.write!"
      end
    end

    it "leaves no .tmp file behind when it refuses an existing target" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(<<-RUBY)
        begin
          Legate.write(#{(file).inspect}, "new")
        rescue Legate::Conflict
        end
        RUBY
        Dir.children(dir).should eq ["f.txt"]
      end
    end

    # The symlink case, corrected 2026-09-03 after the first draft of
    # this test asserted a hole the perimeter already closes. A link
    # pointing OUTSIDE every granted root never reaches this verb:
    # `check_root_maybe_missing` realpaths the deepest existing
    # ancestor, the link resolves to its out-of-root target, and the
    # broker denies with a FatalSignal. Asserted here so the next
    # reader does not re-derive it — and so the day that stops being
    # true, this file says so.
    it "is denied by the perimeter, not by this verb, for a link pointing outside every root" do
      with_tmpdir do |dir|
        with_tmpdir do |outside|
          target = File.join(outside, "secret.txt")
          File.write(target, "secret")
          link = File.join(dir, "link.txt")
          File.symlink(target, link)
          interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
            interp.eval(%(Legate.write(#{(link).inspect}, "clobbered")))
          end
          File.read(target).should eq "secret"
        end
      end
    end

    # What `follow_symlinks: false` actually buys, and the only case
    # where it changes the answer: a DANGLING link resolves to a
    # prospective in-root path, so the broker allows it. Following
    # would report nothing at the destination and let the write
    # replace the link with a regular file; not following refuses the
    # entry that is plainly there.
    it "refuses a dangling symlink at the destination rather than replacing it" do
      with_tmpdir do |dir|
        link = File.join(dir, "link.txt")
        File.symlink(File.join(dir, "never-created.txt"), link)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write(#{(link).inspect}, "clobbered")
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.symlink?(link).should be_true
      end
    end

    # An in-root link to an in-root file: the perimeter says yes, so
    # the refusal here is this verb's own work.
    it "refuses a symlink to a file inside the same root, leaving the target intact" do
      with_tmpdir do |dir|
        target = File.join(dir, "real.txt")
        File.write(target, "original")
        link = File.join(dir, "link.txt")
        File.symlink(target, link)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write(#{(link).inspect}, "clobbered")
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(target).should eq "original"
        File.symlink?(link).should be_true
      end
    end
  end

  describe "Legate.write!" do
    it "replaces existing content rather than appending" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "old content, much longer than new")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(%(Legate.write!(#{(file).inspect}, "new")))
        eval.as_int.should eq 3_i64
        File.read(file).should eq "new"
      end
    end

    it "writes a fresh path exactly as the plain verb does" do
      with_tmpdir do |dir|
        file = File.join(dir, "a", "b", "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(%(Legate.write!(#{(file).inspect}, "hello")))
        eval.as_int.should eq 5_i64
        File.read(file).should eq "hello"
      end
    end

    # The one refusal the bang does NOT lift. Replacing a file is what
    # it is for; turning a directory into a file is not a replacement
    # anyone asked for.
    it "still raises Legate::Conflict when the target is an existing directory" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.write!(#{(target).inspect}, "hi")
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.directory?(target).should be_true
      end
    end

    it "leaves a pre-existing target file completely untouched when the write fails" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(<<-RUBY)
        begin
          Legate.write!(#{(file).inspect}, ["a", 42])
        rescue TypeError
        end
        RUBY
        File.read(file).should eq "original"
      end
    end

    # Same perimeter, same authority, same audit verb — `authorize_write`
    # passes the AUTHORITY name ("write"), not the verb's own name, so
    # the bang is not a way around anything the plain verb is subject
    # to. Worth asserting rather than assuming: a bang variant that
    # quietly skipped authorization would be the worst possible bug in
    # this file.
    it "denies with a FatalSignal for a path outside every granted write root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
            interp.eval(%(Legate.write!(#{(File.join(other, "f.txt")).inspect}, "hi")))
          end
        end
      end
    end

    it "logs exactly one :allowed audit record per invocation" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.write!(#{(file).inspect}, "hi")))
        records = interp.broker.audit_log.records.select { |r| r.verb == "write" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    it "counts against the total_write budget the same way" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        limits = Legate::Limits.new(total_write: 3_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir], limits: limits))
        expect_raises(Legate::FatalSignal) do
          interp.eval(%(Legate.write!(#{(file).inspect}, "this is way more than 3 bytes")))
        end
      end
    end
  end
end
