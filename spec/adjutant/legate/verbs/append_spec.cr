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
  describe "Legate.append" do
    it "creates the file if it doesn't exist yet" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(%(Legate.append(#{(file).inspect}, "hello")))
        eval.as_int.should eq 5_i64
        File.read(file).should eq "hello"
      end
    end

    it "adds to the END of existing content, does not overwrite" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "existing-")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.append(#{(file).inspect}, "new")))
        File.read(file).should eq "existing-new"
      end
    end

    it "accumulates correctly across multiple separate calls" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.append(#{(file).inspect}, "a")))
        interp.eval(%(Legate.append(#{(file).inspect}, "b")))
        interp.eval(%(Legate.append(#{(file).inspect}, "c")))
        File.read(file).should eq "abc"
      end
    end

    it "appends an Array of Strings, concatenated in order" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(%(Legate.append(#{(file).inspect}, ["a", "b", "c"])))
        eval.as_int.should eq 3_i64
        File.read(file).should eq "abc"
      end
    end

    it "appends a Legate stream's elements without materializing them all first" do
      with_tmpdir do |dir|
        src = File.join(dir, "src.txt")
        dest = File.join(dir, "dest.txt")
        File.write(src, "alpha\nbeta\n")
        File.write(dest, "existing\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.append(#{(dest).inspect}, Legate.lines(#{(src).inspect}).map { |l| l.upcase + "\\n" })
        RUBY
        eval.as_int.should eq 11_i64 # "ALPHA\nBETA\n"
        File.read(dest).should eq "existing\nALPHA\nBETA\n"
      end
    end

    it "creates parent directories automatically, recursively" do
      with_tmpdir do |dir|
        file = File.join(dir, "a", "b", "c", "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.append(#{(file).inspect}, "hi")))
        File.read(file).should eq "hi"
      end
    end

    it "raises Legate::Conflict when the target is an existing directory" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.append(#{(target).inspect}, "hi")
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
          Legate.append(#{(file).inspect}, 42)
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "UNLIKE write: a partial failure leaves whatever was already appended, since append makes no atomicity guarantee" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "start-")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(<<-RUBY)
        begin
          Legate.append(#{(file).inspect}, ["a", "b", 42, "d"])
        rescue TypeError
        end
        RUBY
        # "a" and "b" were genuinely flushed to disk before the
        # TypeError on the 3rd element — no rollback, matching this
        # verb's own documented (non-)guarantee.
        File.read(file).should eq "start-ab"
      end
    end

    it "raises FatalSignal on total_write budget exhaustion" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        limits = Legate::Limits.new(total_write: 3_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir], limits: limits))
        expect_raises(Legate::FatalSignal) do
          interp.eval(%(Legate.append(#{(file).inspect}, "this is way more than 3 bytes")))
        end
      end
    end

    it "denies with a FatalSignal for a path outside every granted write root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
            interp.eval(%(Legate.append(#{(File.join(other, "f.txt")).inspect}, "hi")))
          end
        end
      end
    end

    it "logs exactly one :allowed audit record per invocation" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.append(#{(file).inspect}, "hi")))
        records = interp.broker.audit_log.records.select { |r| r.verb == "write" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end
  end
end
