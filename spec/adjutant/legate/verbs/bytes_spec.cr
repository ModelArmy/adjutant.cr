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
  describe "Legate.bytes" do
    it "yields the whole file as a single chunk when chunk: exceeds the file size" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello world")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.bytes(#{(file).inspect}).to_a.map { |c| c.to_s }
        RUBY
        eval.as_array.to_a.map(&.as_string).should eq ["hello world"]
      end
    end

    it "splits content into multiple chunks of the requested size" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.bytes(#{(file).inspect}, chunk: 4).to_a.map { |c| c.to_s }
        RUBY
        eval.as_array.to_a.map(&.as_string).should eq ["0123", "4567", "89"]
      end
    end

    it "returns an empty Array for an empty file" do
      with_tmpdir do |dir|
        file = File.join(dir, "empty.txt")
        File.write(file, "")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.bytes(#{(file).inspect}).to_a))
        eval.as_array.to_a.should be_empty
      end
    end

    it "preserves exact bytes for genuinely non-UTF-8 binary content" do
      with_tmpdir do |dir|
        file = File.join(dir, "bin.dat")
        raw = ::Bytes[0xFF, 0x00, 0xC3, 0x28, 0x41] # includes an invalid UTF-8 sequence + a plain 'A'
        File.write(file, raw)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.bytes(#{(file).inspect}).to_a.first.to_a
        RUBY
        eval.as_array.to_a.map(&.as_int).should eq [0xFF_i64, 0x00_i64, 0xC3_i64, 0x28_i64, 0x41_i64]
      end
    end

    it "raises Legate::NotFound eagerly, at construction, for a missing path under a granted root" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.bytes(#{(File.join(dir, "nope.txt")).inspect})
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
          File.write(File.join(other, "f.txt"), "hi")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.bytes(#{(File.join(other, "f.txt")).inspect})))
          end
        end
      end
    end

    it "raises Legate::EOF on a second full iteration (single-pass, amended §6.1)" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        s = Legate.bytes(#{(file).inspect})
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

    it "records bytes into the shared Budget progressively, per chunk" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789") # 10 bytes
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.bytes(#{(file).inspect}, chunk: 4).to_a))
        interp.broker.budget.total_read.should eq 10_i64
      end
    end

    it "raises FatalSignal :exhausted mid-stream once total_read budget is exceeded" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789") # 10 bytes
        limits = Legate::Limits.new(total_read: 5_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], limits: limits))
        expect_raises(Legate::FatalSignal, /total_read budget exceeded/) do
          interp.eval(%(Legate.bytes(#{(file).inspect}, chunk: 4).to_a))
        end
      end
    end

    it "denies with no read grant at all" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "f.txt"), "hi")
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.bytes(#{(File.join(dir, "f.txt")).inspect})))
        end
      end
    end

    it "logs exactly one :allowed audit record at construction" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.bytes(#{(file).inspect})))
        records = interp.broker.audit_log.records.select { |r| r.verb == "read" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    it "raises TypeError (R036) for a wrong-typed chunk: kwarg, not a raw Crystal crash" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.bytes(#{(file).inspect}, chunk: "big")
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
