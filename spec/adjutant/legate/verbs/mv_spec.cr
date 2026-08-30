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

# See mkdir_spec.cr's own identical helper for the full explanation.
private def posix(path : String) : String
  ::Path.new(path).to_posix.to_s
end

module Adjutant
  private def self.move_grants(dir : String) : Legate::Grants
    Legate::Grants.new(delete_roots: [dir], write_roots: [dir])
  end

  describe "Legate.mv" do
    it "moves a file and returns a Path to the destination" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        to = File.join(dir, "b.txt")
        File.write(from, "content")
        interp, _ = make_interp(grants: move_grants(dir))
        eval = interp.eval(%(Legate.mv(#{(from).inspect}, #{(to).inspect}).to_s))
        eval.as_string.should eq posix(to)
        File.exists?(from).should be_false
        File.read(to).should eq "content"
      end
    end

    it "moves a whole directory tree" do
      with_tmpdir do |dir|
        from = File.join(dir, "src")
        to = File.join(dir, "dest")
        Dir.mkdir(from)
        File.write(File.join(from, "a.txt"), "a")
        interp, _ = make_interp(grants: move_grants(dir))
        interp.eval(%(Legate.mv(#{(from).inspect}, #{(to).inspect})))
        Dir.exists?(from).should be_false
        File.read(File.join(to, "a.txt")).should eq "a"
      end
    end

    it "creates parent directories of the destination automatically" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        to = File.join(dir, "x", "y", "b.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: move_grants(dir))
        interp.eval(%(Legate.mv(#{(from).inspect}, #{(to).inspect})))
        File.read(to).should eq "hi"
      end
    end

    # File-over-file overwrites, matching what `write`/`cp` already do
    # to an existing target rather than inventing a stricter rule for
    # this verb alone.
    it "overwrites an existing file destination" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        to = File.join(dir, "b.txt")
        File.write(from, "new")
        File.write(to, "old")
        interp, _ = make_interp(grants: move_grants(dir))
        interp.eval(%(Legate.mv(#{(from).inspect}, #{(to).inspect})))
        File.read(to).should eq "new"
      end
    end

    it "raises Legate::NotFound when the source doesn't exist" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: move_grants(dir))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.mv(#{(File.join(dir, "gone.txt")).inspect}, #{(File.join(dir, "b.txt")).inspect})
          "no error"
        rescue Legate::NotFound
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises Legate::Conflict when the destination is a directory and the source is a file" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        to = File.join(dir, "d")
        File.write(from, "hi")
        Dir.mkdir(to)
        interp, _ = make_interp(grants: move_grants(dir))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.mv(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.exists?(from).should be_true
      end
    end

    it "raises Legate::Conflict when the destination is a non-empty directory and the source is a directory" do
      with_tmpdir do |dir|
        from = File.join(dir, "src")
        to = File.join(dir, "dest")
        Dir.mkdir(from)
        Dir.mkdir(to)
        File.write(File.join(to, "occupied.txt"), "x")
        interp, _ = make_interp(grants: move_grants(dir))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.mv(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(File.join(to, "occupied.txt")).should eq "x"
      end
    end

    # THE decision this verb exists to encode — the delete-without-
    # write case §4.4's literal text would have allowed. A script that
    # can delete inside `dir` must NOT be able to place content
    # anywhere it likes by calling it a move.
    it "denies a move with a delete grant but no write grant" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        to = File.join(dir, "b.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
          interp.eval(%(Legate.mv(#{(from).inspect}, #{(to).inspect})))
        end
        File.exists?(from).should be_true
        File.exists?(to).should be_false
      end
    end

    # The mirror case, and the one §4.4 states outright: `write`
    # alone cannot achieve a move either.
    it "denies a move with a write grant but no delete grant" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        to = File.join(dir, "b.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
          interp.eval(%(Legate.mv(#{(from).inspect}, #{(to).inspect})))
        end
        File.exists?(from).should be_true
      end
    end

    # Both roots granted, but not the same root — the destination
    # falls outside the write grant, so the move is still refused.
    it "denies a move whose destination is outside every granted write root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          from = File.join(dir, "a.txt")
          File.write(from, "hi")
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir], write_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
            interp.eval(%(Legate.mv(#{(from).inspect}, #{(File.join(other, "b.txt")).inspect})))
          end
          File.exists?(from).should be_true
        end
      end
    end

    it "moves a symlink itself, never the file it points at" do
      {% if flag?(:unix) %}
        with_tmpdir do |dir|
          real = File.join(dir, "real.txt")
          link = File.join(dir, "link.txt")
          moved = File.join(dir, "moved.txt")
          File.write(real, "content")
          File.symlink(real, link)
          interp, _ = make_interp(grants: move_grants(dir))
          interp.eval(%(Legate.mv(#{(link).inspect}, #{(moved).inspect})))
          File.symlink?(moved).should be_true
          File.exists?(link).should be_false
          File.read(real).should eq "content"
        end
      {% end %}
    end

    it "logs exactly one :allowed delete record and one :allowed write record per invocation" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: move_grants(dir))
        interp.eval(%(Legate.mv(#{(from).inspect}, #{(File.join(dir, "b.txt")).inspect})))
        records = interp.broker.audit_log.records
        deletes = records.select { |r| r.verb == "delete" }
        writes = records.select { |r| r.verb == "write" }
        deletes.size.should eq 1
        deletes.first.decision.should eq :allowed
        writes.size.should eq 1
        writes.first.decision.should eq :allowed
      end
    end

    # A same-filesystem move is a bare `rename` — it moves no bytes,
    # so it consumes no read/write byte budget. The cross-device
    # fallback DOES consume both; that asymmetry is documented in
    # `mv.cr` and is not exercised here, since forcing a genuine
    # second filesystem into a spec isn't portable.
    it "consumes no byte budget for a same-filesystem move" do
      with_tmpdir do |dir|
        from = File.join(dir, "a.txt")
        File.write(from, "a" * 1024)
        interp, _ = make_interp(grants: move_grants(dir))
        interp.eval(%(Legate.mv(#{(from).inspect}, #{(File.join(dir, "b.txt")).inspect})))
        interp.broker.budget.total_read.should eq 0
        interp.broker.budget.total_write.should eq 0
      end
    end
  end
end
