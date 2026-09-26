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

private def budget(total_read : Int64? = nil) : Adjutant::Budget
  Adjutant::Budget.new(Adjutant::ResourceLimits.new(total_read: total_read))
end

# `Legate.mv`'s cross-device fallback can't be reached from a spec
# without two filesystems, so the copy it uses is tested directly.
module Adjutant
  describe Legate::TreeCopy do
    it "copies a tree, calling on_file once for each regular file" do
      with_tmpdir do |dir|
        from = File.join(dir, "from")
        Dir.mkdir_p(File.join(from, "sub"))
        File.write(File.join(from, "a.txt"), "aa")
        File.write(File.join(from, "sub", "b.txt"), "bbb")
        to = File.join(dir, "to")
        seen = [] of String
        b = budget
        copier = Legate::TreeCopy.new(b) do |file|
          seen << File.basename(file)
          nil
        end
        copier.copy_entry(from, to)
        File.read(File.join(to, "a.txt")).should eq "aa"
        File.read(File.join(to, "sub", "b.txt")).should eq "bbb"
        seen.sort.should eq ["a.txt", "b.txt"]
        b.total_read.should eq 5
        b.total_write.should eq 5
      end
    end

    it "stops when on_file raises, before the file is read" do
      with_tmpdir do |dir|
        from = File.join(dir, "from")
        Dir.mkdir(from)
        File.write(File.join(from, "a.txt"), "aa")
        b = budget
        expect_raises(Exception, "refused") do
          Legate::TreeCopy.new(b) { |_file| raise "refused" }.copy_entry(from, File.join(dir, "to"))
        end
        b.total_read.should eq 0
      end
    end

    it "records the read budget per chunk, so an exhausted budget stops the copy" do
      with_tmpdir do |dir|
        from = File.join(dir, "from")
        Dir.mkdir(from)
        File.write(File.join(from, "a.txt"), "more than three bytes")
        expect_raises(FatalSignal) do
          Legate::TreeCopy.new(budget(total_read: 3_i64)) { }.copy_entry(from, File.join(dir, "to"))
        end
      end
    end

    # The Windows runner can't create symlinks or FIFOs; see
    # authorization_spec.cr's pending test.
    {% if flag?(:windows) %}
      pending "copies symlinks as links and refuses special files (needs symlinks)" { }
    {% else %}
      it "copies a symlink named as the root as a link, as a rename would move it" do
        with_tmpdir do |dir|
          with_tmpdir do |outside|
            target = File.join(outside, "secret.txt")
            File.write(target, "secret")
            link = File.join(dir, "link")
            File.symlink(target, link)
            to = File.join(dir, "moved")
            b = budget
            Legate::TreeCopy.new(b) { |_file| raise "no file should be read" }.copy_entry(link, to)
            File.readlink(to).should eq target
            b.total_read.should eq 0
          end
        end
      end

      it "copies links inside the tree as links, including one to an ancestor" do
        with_tmpdir do |dir|
          with_tmpdir do |outside|
            from = File.join(dir, "from")
            Dir.mkdir(from)
            File.symlink(outside, File.join(from, "out"))
            File.symlink("..", File.join(from, "up"))
            to = File.join(dir, "to")
            Legate::TreeCopy.new(budget) { |_file| raise "no file should be read" }.copy_entry(from, to)
            File.readlink(File.join(to, "out")).should eq outside
            File.readlink(File.join(to, "up")).should eq ".."
          end
        end
      end

      it "raises SpecialFile for a FIFO instead of opening it" do
        with_tmpdir do |dir|
          from = File.join(dir, "from")
          Dir.mkdir(from)
          fifo = File.join(from, "pipe")
          Process.run("mkfifo", [fifo]).success?.should be_true
          expect_raises(Legate::TreeCopy::SpecialFile, /pipe is not a regular file/) do
            Legate::TreeCopy.new(budget) { |_file| raise "no file should be read" }.copy_entry(from, File.join(dir, "to"))
          end
        end
      end
    {% end %}
  end
end
