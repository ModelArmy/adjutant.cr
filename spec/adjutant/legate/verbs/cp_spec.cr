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
  describe "Legate.cp" do
    it "copies a file's exact content and returns a Path to the destination" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        to = File.join(dir, "dest.txt")
        File.write(from, "hello world")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(%(Legate.cp(#{(from).inspect}, #{(to).inspect}).to_s))
        eval.as_string.should eq posix(to)
        File.read(to).should eq "hello world"
      end
    end

    it "copies bytes exactly, even invalid UTF-8 — cp doesn't decode content" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.bin")
        to = File.join(dir, "dest.bin")
        raw = ::Bytes[0x68, 0x69, 0xFF]
        File.write(from, raw)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp(#{(from).inspect}, #{(to).inspect})))
        File.read(to).to_slice.should eq raw
      end
    end

    it "creates parent directories of the destination automatically" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        to = File.join(dir, "a", "b", "dest.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp(#{(from).inspect}, #{(to).inspect})))
        File.read(to).should eq "hi"
      end
    end

    it "leaves no .tmp file behind after a successful copy" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        to = File.join(dir, "dest.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp(#{(from).inspect}, #{(to).inspect})))
        Dir.children(dir).to_set.should eq Set{"src.txt", "dest.txt"}
      end
    end

    it "raises Legate::NotFound when the source doesn't exist" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(File.join(dir, "nope.txt")).inspect}, #{(File.join(dir, "dest.txt")).inspect})
          "no error"
        rescue Legate::NotFound
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises Legate::Conflict when the destination is an existing directory" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "hi")
        to = File.join(dir, "sub")
        Dir.mkdir(to)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises Legate::Conflict for a directory source without recursive: true" do
      with_tmpdir do |dir|
        from = File.join(dir, "src_dir")
        Dir.mkdir(from)
        to = File.join(dir, "dest_dir")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "recursively copies a whole directory tree with recursive: true" do
      with_tmpdir do |dir|
        from = File.join(dir, "src_dir")
        Dir.mkdir(from)
        Dir.mkdir(File.join(from, "sub"))
        File.write(File.join(from, "top.txt"), "top")
        File.write(File.join(from, "sub", "nested.txt"), "nested")
        to = File.join(dir, "dest_dir")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp(#{(from).inspect}, #{(to).inspect}, recursive: true)))
        File.read(File.join(to, "top.txt")).should eq "top"
        File.read(File.join(to, "sub", "nested.txt")).should eq "nested"
      end
    end

    it "raises Legate::Conflict copying a directory onto an existing file" do
      with_tmpdir do |dir|
        from = File.join(dir, "src_dir")
        Dir.mkdir(from)
        to = File.join(dir, "dest.txt")
        File.write(to, "existing file")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(to).inspect}, recursive: true)
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "denies with a FatalSignal when there's a write grant but no read grant on the source (the exact exfiltration path dual-authorization closes)" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "secret")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.cp(#{(from).inspect}, #{(File.join(dir, "dest.txt")).inspect})))
        end
      end
    end

    it "denies with a FatalSignal when there's a read grant but no write grant on the destination" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
          interp.eval(%(Legate.cp(#{(from).inspect}, #{(File.join(dir, "dest.txt")).inspect})))
        end
      end
    end

    it "raises FatalSignal on read-budget exhaustion" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "this is way more than three bytes")
        limits = Legate::Limits.new(total_read: 3_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir], limits: limits))
        expect_raises(Legate::FatalSignal) do
          interp.eval(%(Legate.cp(#{(from).inspect}, #{(File.join(dir, "dest.txt")).inspect})))
        end
      end
    end

    it "raises FatalSignal on write-budget exhaustion" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "this is way more than three bytes")
        limits = Legate::Limits.new(total_write: 3_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir], limits: limits))
        expect_raises(Legate::FatalSignal) do
          interp.eval(%(Legate.cp(#{(from).inspect}, #{(File.join(dir, "dest.txt")).inspect})))
        end
      end
    end

    it "logs exactly one :allowed read record AND one :allowed write record per invocation" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp(#{(from).inspect}, #{(File.join(dir, "dest.txt")).inspect})))
        reads = interp.broker.audit_log.records.select { |r| r.verb == "read" }
        writes = interp.broker.audit_log.records.select { |r| r.verb == "write" }
        reads.size.should eq 1
        reads.first.decision.should eq :allowed
        writes.size.should eq 1
        writes.first.decision.should eq :allowed
      end
    end

    # The destination rule. Each refusal asserts that the previous
    # content SURVIVED, not merely that an exception was raised — a
    # verb that destroyed the destination and then complained would
    # pass a bare `expect_raises`, and that is the exact failure this
    # split exists to fix.
    it "raises Legate::Conflict when the destination file already exists" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        to = File.join(dir, "dest.txt")
        File.write(from, "new")
        File.write(to, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(to).should eq "original"
      end
    end

    it "names Legate.cp! in the Conflict message, per principle 6" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        to = File.join(dir, "dest.txt")
        File.write(from, "new")
        File.write(to, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict => e
          e.message
        end
        RUBY
        eval.as_string.should contain "Legate.cp!"
      end
    end

    # The directory clobber, which was the worse of the two: the old
    # verb `rm_rf`'d the whole destination tree before renaming its
    # own into place. `keep.txt` is the witness — it is not in the
    # source tree, so if the destination were replaced rather than
    # refused, it would be gone.
    it "raises Legate::Conflict rather than replacing an existing destination tree" do
      with_tmpdir do |dir|
        from = File.join(dir, "src")
        Dir.mkdir(from)
        File.write(File.join(from, "a.txt"), "a")
        to = File.join(dir, "dest")
        Dir.mkdir(to)
        File.write(File.join(to, "keep.txt"), "keep")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(to).inspect}, recursive: true)
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(File.join(to, "keep.txt")).should eq "keep"
      end
    end

    # Ordering: a source problem is reported before a destination
    # one. A script that got `recursive:` wrong should be told that,
    # not told about the destination it would also have had to deal
    # with.
    it "reports the missing-recursive refusal before the occupied-destination one" do
      with_tmpdir do |dir|
        from = File.join(dir, "src")
        Dir.mkdir(from)
        to = File.join(dir, "dest")
        Dir.mkdir(to)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict => e
          e.message
        end
        RUBY
        eval.as_string.should contain "recursive: true"
      end
    end

    it "refuses a dangling symlink at the destination rather than replacing it" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "new")
        link = File.join(dir, "dest.txt")
        File.symlink(File.join(dir, "never-created.txt"), link)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp(#{(from).inspect}, #{(link).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.symlink?(link).should be_true
      end
    end
  end

  describe "Legate.cp!" do
    it "replaces an existing destination file" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        to = File.join(dir, "dest.txt")
        File.write(from, "new")
        File.write(to, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp!(#{(from).inspect}, #{(to).inspect})))
        File.read(to).should eq "new"
      end
    end

    it "copies to a fresh destination exactly as the plain verb does" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        to = File.join(dir, "a", "b", "dest.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp!(#{(from).inspect}, #{(to).inspect})))
        File.read(to).should eq "hi"
      end
    end

    # REPLACES the destination tree, it does not merge into it. This
    # is the behaviour a `cp -r` habit gets wrong, so it is asserted
    # explicitly rather than left implied: `keep.txt` is absent from
    # the source and MUST be gone afterwards.
    it "replaces an existing destination tree wholesale rather than merging into it" do
      with_tmpdir do |dir|
        from = File.join(dir, "src")
        Dir.mkdir(from)
        File.write(File.join(from, "a.txt"), "a")
        to = File.join(dir, "dest")
        Dir.mkdir(to)
        File.write(File.join(to, "keep.txt"), "keep")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        interp.eval(%(Legate.cp!(#{(from).inspect}, #{(to).inspect}, recursive: true)))
        File.read(File.join(to, "a.txt")).should eq "a"
        File.exists?(File.join(to, "keep.txt")).should be_false
      end
    end

    # The refusals the bang does NOT lift. Replacing like with like is
    # what it is for; swapping a file for a tree or a tree for a file
    # is never what a caller meant.
    it "still raises Legate::Conflict copying a file onto an existing directory" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "hi")
        to = File.join(dir, "dest")
        Dir.mkdir(to)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp!(#{(from).inspect}, #{(to).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.directory?(to).should be_true
      end
    end

    it "still raises Legate::Conflict copying a directory onto an existing file" do
      with_tmpdir do |dir|
        from = File.join(dir, "src")
        Dir.mkdir(from)
        to = File.join(dir, "dest.txt")
        File.write(to, "original")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp!(#{(from).inspect}, #{(to).inspect}, recursive: true)
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        File.read(to).should eq "original"
      end
    end

    it "still requires recursive: true for a directory source" do
      with_tmpdir do |dir|
        from = File.join(dir, "src")
        Dir.mkdir(from)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.cp!(#{(from).inspect}, #{(File.join(dir, "dest")).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    # Same dual authorization as the plain verb — the bang is not a
    # way around the perimeter, which would be the worst bug this
    # file could hide.
    it "denies with a FatalSignal when there's a write grant but no read grant on the source" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.cp!(#{(from).inspect}, #{(File.join(dir, "dest.txt")).inspect})))
        end
      end
    end

    it "denies with a FatalSignal when there's a read grant but no write grant on the destination" do
      with_tmpdir do |dir|
        from = File.join(dir, "src.txt")
        File.write(from, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
          interp.eval(%(Legate.cp!(#{(from).inspect}, #{(File.join(dir, "dest.txt")).inspect})))
        end
      end
    end
  end
end
