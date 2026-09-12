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

# See list_spec.cr's own identical helper for the full explanation:
# `Legate::Path` renders consistently POSIX-style on every platform by
# design, unlike `File.join`'s native-separator output.
private def posix(path : String) : String
  ::Path.new(path).to_posix.to_s
end

module Adjutant
  describe "Legate.grep" do
    it "finds lines matching a literal String pattern" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "one\nfoo bar\nthree\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.grep("foo", #{(File.join(dir, "*.txt")).inspect}).map { |m| m.text }
        RUBY
        eval.as_array.to_a.map(&.as_string).should eq ["foo bar"]
      end
    end

    it "finds lines matching a Regexp pattern" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "abc123\nxyz\nabc456\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.grep(/abc\\d+/, #{(File.join(dir, "*.txt")).inspect}).map { |m| m.text }
        RUBY
        eval.as_array.to_a.map(&.as_string).should eq ["abc123", "abc456"]
      end
    end

    it "reports 1-based line_no and the matched Path" do
      with_tmpdir do |dir|
        file = File.join(dir, "a.txt")
        File.write(file, "one\ntwo\nthree\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        m = Legate.grep("two", #{(File.join(dir, "*.txt")).inspect}).first
        [m.line_no, m.path.to_s]
        RUBY
        arr = eval.as_array.to_a
        arr[0].as_int.should eq 2_i64
        arr[1].as_string.should eq posix(file)
      end
    end

    it "includes before/after context lines when context: is given" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "one\ntwo\nMATCH\nfour\nfive\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        m = Legate.grep("MATCH", #{(File.join(dir, "*.txt")).inspect}, context: 1).first
        [m.before, m.after]
        RUBY
        arr = eval.as_array.to_a
        arr[0].as_array.to_a.map(&.as_string).should eq ["two"]
        arr[1].as_array.to_a.map(&.as_string).should eq ["four"]
      end
    end

    it "before/after are empty Arrays when context: is omitted (default 0)" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "one\nMATCH\nthree\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        m = Legate.grep("MATCH", #{(File.join(dir, "*.txt")).inspect}).first
        [m.before, m.after]
        RUBY
        arr = eval.as_array.to_a
        arr[0].as_array.to_a.should be_empty
        arr[1].as_array.to_a.should be_empty
      end
    end

    it "accepts an Array of paths, mixing patterns and literal files" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hello\n")
        File.write(File.join(dir, "b.log"), "hello\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.grep("hello", [#{(File.join(dir, "*.txt")).inspect}, #{(File.join(dir, "b.log")).inspect}]).length
        RUBY
        eval.as_int.should eq 2_i64
      end
    end

    it "skips binary files (a NUL byte within the first bytes)" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hello\n")
        File.write(File.join(dir, "b.bin"), ::Bytes[0x68, 0x65, 0x00, 0x6c, 0x6f]) # "he\0lo"
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.grep("he", #{(File.join(dir, "*")).inspect}).map { |m| m.path.basename }
        RUBY
        eval.as_array.to_a.map(&.as_string).should eq ["a.txt"]
      end
    end

    it "returns an empty Array when nothing matches" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "nothing interesting\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.grep("zzz", #{(File.join(dir, "*.txt")).inspect})))
        eval.as_array.to_a.should be_empty
      end
    end

    it "raises Legate::TooMany once matches exceed limit:" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "x\nx\nx\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.grep("x", #{(File.join(dir, "*.txt")).inspect}, limit: 2)
          "no error"
        rescue Legate::TooMany
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises ArgumentError (R018) when pattern is missing" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.grep
        "no error"
      rescue ArgumentError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R019) when pattern is neither String nor Regexp" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.grep(42, "somewhere/*")
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises FatalSignal (denied) for a path outside every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          File.write(File.join(other, "a.txt"), "hello\n")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.grep("hello", #{(File.join(other, "*.txt")).inspect})))
          end
        end
      end
    end

    it "logs exactly one :allowed audit record per distinct fixed-prefix directory, not per matched file" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hello\n")
        File.write(File.join(dir, "b.txt"), "hello\n")
        File.write(File.join(dir, "c.txt"), "hello\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.grep("hello", #{(File.join(dir, "*.txt")).inspect})))
        records = interp.broker.audit_log.records.select { |r| r.verb == "read" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    it "raises TypeError (R036) for a wrong-typed context: kwarg, not a raw Crystal crash" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hi\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.grep("hi", #{(File.join(dir, "*.txt")).inspect}, context: "some")
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end
  end
end
