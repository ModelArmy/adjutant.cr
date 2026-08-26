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
  describe "Legate.lines" do
    it "splits content on newlines, without the trailing newline in each line" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "one\ntwo\nthree\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.lines(#{(file).inspect}).to_a))
        eval.as_array.to_a.map(&.as_string).should eq ["one", "two", "three"]
      end
    end

    it "yields a final line with no trailing newline" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "one\ntwo")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.lines(#{(file).inspect}).to_a))
        eval.as_array.to_a.map(&.as_string).should eq ["one", "two"]
      end
    end

    it "returns an empty Array for an empty file" do
      with_tmpdir do |dir|
        file = File.join(dir, "empty.txt")
        File.write(file, "")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.lines(#{(file).inspect}).to_a))
        eval.as_array.to_a.should be_empty
      end
    end

    it "handles a line longer than the internal read chunk size" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        long_line = "x" * 200_000 # several multiples of the 65_536-byte read chunk
        File.write(file, "#{long_line}\nshort\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.lines(#{(file).inspect}).to_a.map { |l| l.length }))
        eval.as_array.to_a.map(&.as_int).should eq [200_000_i64, 5_i64]
      end
    end

    it "raises Legate::TooLarge mid-iteration when a line exceeds max_line, without buffering the whole file" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "short\n#{"y" * 1000}\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        s = Legate.lines(#{(file).inspect}, max_line: 100)
        begin
          s.to_a
        rescue Legate::TooLarge => e
          "caught: \#{e.message}"
        end
        RUBY
        eval.as_string.should match(/caught: .*max_line/)
      end
    end

    it "raises Legate::TooLarge for a single line with no newline at all, exceeding max_line" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "z" * 1000) # no trailing newline
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.lines(#{(file).inspect}, max_line: 100).to_a
        rescue Legate::TooLarge => e
          "caught: \#{e.message}"
        end
        RUBY
        eval.as_string.should match(/caught: .*max_line/)
      end
    end

    it "replaces invalid UTF-8 with U+FFFD by default (scrub: true)" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        raw = ::Bytes[0x68, 0x69, 0xFF, 0x0A] # "hi" + invalid byte + newline
        File.write(file, raw)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.lines(#{(file).inspect}).to_a))
        eval.as_array.to_a.map(&.as_string).should eq ["hi\uFFFD"]
      end
    end

    it "raises Legate::Malformed on invalid UTF-8 when scrub: false" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        raw = ::Bytes[0x68, 0x69, 0xFF, 0x0A]
        File.write(file, raw)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.lines(#{(file).inspect}, scrub: false).to_a
          "no error"
        rescue Legate::Malformed
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises Legate::NotFound eagerly, at construction, for a missing path under a granted root" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.lines(#{(File.join(dir, "nope.txt")).inspect})
          "no error"
        rescue Legate::NotFound
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises FatalSignal (denied) eagerly, at construction, for a path outside every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          File.write(File.join(other, "f.txt"), "hi\n")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.lines(#{(File.join(other, "f.txt")).inspect})))
          end
        end
      end
    end

    it "raises Legate::EOF on a second full iteration (single-pass, §6.1)" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "one\ntwo\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        s = Legate.lines(#{(file).inspect})
        s.to_a
        begin
          s.to_a
          "no error"
        rescue Legate::EOF
          "eof"
        end
        RUBY
        eval.as_string.should eq "eof"
      end
    end

    it "records bytes into the shared Budget progressively, per chunk read" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "one\ntwo\nthree\n") # 14 bytes
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.lines(#{(file).inspect}).to_a))
        interp.broker.budget.total_read.should eq 14_i64
      end
    end

    it "denies with no read grant at all" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "f.txt"), "hi\n")
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.lines(#{(File.join(dir, "f.txt")).inspect})))
        end
      end
    end

    it "logs exactly one :allowed audit record at construction" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.lines(#{(file).inspect})))
        records = interp.broker.audit_log.records.select { |r| r.verb == "read" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end
  end
end
