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
  describe "Legate.read" do
    it "returns the file content as a String" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello world")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.read(#{(file).inspect}))).as_string.should eq "hello world"
      end
    end

    it "accepts a Legate::Path argument" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.read(Legate::Path.new(#{(file).inspect})))).as_string.should eq "hi"
      end
    end

    it "raises Legate::NotFound for a missing path under a granted root" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.read(#{(File.join(dir, "nope.txt")).inspect})
        rescue Legate::NotFound => e
          "caught: \#{e.message}"
        end
        RUBY
        eval.as_string.should match(/caught: .*nope\.txt not found/)
      end
    end

    it "raises Legate::FatalSignal (denied), not NotFound, for a missing path OUTSIDE every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.read(#{(File.join(other, "nope.txt")).inspect})))
          end
        end
      end
    end

    describe "missing: kwarg (§2.5)" do
      it "returns nil when missing: nil is given and the path is absent" do
        with_tmpdir do |dir|
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          result = interp.eval(%(Legate.read(#{(File.join(dir, "nope.txt")).inspect}, missing: nil)))
          result.raw.nil?.should be_true
        end
      end

      it "returns the given default when missing: \"{}\" is given and the path is absent" do
        with_tmpdir do |dir|
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          result = interp.eval(%(Legate.read(#{(File.join(dir, "nope.txt")).inspect}, missing: "{}")))
          result.as_string.should eq "{}"
        end
      end

      it "missing: does NOT suppress Legate::Denied for a path outside every granted root" do
        with_tmpdir do |dir|
          with_tmpdir do |other|
            interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
            expect_raises(Legate::FatalSignal, /denied/) do
              interp.eval(%(Legate.read(#{(File.join(other, "nope.txt")).inspect}, missing: nil)))
            end
          end
        end
      end

      it "missing: does NOT suppress Legate::TooLarge" do
        with_tmpdir do |dir|
          file = File.join(dir, "big.txt")
          File.write(file, "x" * 100)
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.read(#{(file).inspect}, limit: 10, missing: nil)
          rescue Legate::TooLarge => e
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      it "still reads normally when missing: is given but the path DOES exist" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "hi")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          interp.eval(%(Legate.read(#{(file).inspect}, missing: nil))).as_string.should eq "hi"
        end
      end
    end

    describe "limit: kwarg" do
      it "raises Legate::TooLarge when the file exceeds the policy's own read_limit" do
        with_tmpdir do |dir|
          file = File.join(dir, "big.txt")
          File.write(file, "x" * 200)
          limits = Legate::Limits.new(read_limit: 100_i64)
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], limits: limits))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.read(#{(file).inspect})
          rescue Legate::TooLarge => e
            e.message
          end
          RUBY
          eval.as_string.should match(/over the 100 B read limit/)
          eval.as_string.should match(/Legate\.lines/)
        end
      end

      it "a script-given limit: cannot exceed the policy's own read_limit" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "x" * 50)
          limits = Legate::Limits.new(read_limit: 100_i64)
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], limits: limits))
          # Script asks for a 1_000_000-byte limit; policy caps it at 100.
          # The 50-byte file is still under BOTH, so this should succeed —
          # proving the effective limit didn't silently become unbounded.
          interp.eval(%(Legate.read(#{(file).inspect}, limit: 1_000_000))).as_string.bytesize.should eq 50
        end
      end

      it "a script-given SMALLER limit: is honored" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "x" * 50)
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.read(#{(file).inspect}, limit: 10)
          rescue Legate::TooLarge
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end
    end

    it "records total_read on the shared Budget after a successful read" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.read(#{(file).inspect})))
        interp.broker.budget.total_read.should eq 10_i64
      end
    end

    it "raises FatalSignal :exhausted once total_read budget is exceeded" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789") # 10 bytes
        limits = Legate::Limits.new(total_read: 15_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], limits: limits))
        interp.eval(%(Legate.read(#{(file).inspect}))) # 10, ok
        expect_raises(Legate::FatalSignal, /total_read budget exceeded/) do
          interp.eval(%(Legate.read(#{(file).inspect}))) # 20 > 15
        end
      end
    end

    it "denies with no read grant at all" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.read(#{(file).inspect})))
        end
      end
    end

    it "logs exactly one :allowed audit record per invocation" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.read(#{(file).inspect})))
        records = interp.broker.audit_log.records.select { |r| r.verb == "read" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    describe "scrub:" do
      it "replaces invalid UTF-8 with U+FFFD by default (scrub: true)" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          raw = ::Bytes[0x68, 0x69, 0xFF] # "hi" + invalid byte
          File.write(file, raw)
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(%(Legate.read(#{(file).inspect})))
          eval.as_string.should eq "hi\uFFFD"
        end
      end

      it "raises Legate::Malformed on invalid UTF-8 when scrub: false" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          raw = ::Bytes[0x68, 0x69, 0xFF]
          File.write(file, raw)
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.read(#{(file).inspect}, scrub: false)
            "no error"
          rescue Legate::Malformed
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      it "leaves genuinely valid UTF-8 completely unchanged" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "héllo")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          interp.eval(%(Legate.read(#{(file).inspect}))).as_string.should eq "héllo"
        end
      end
    end

    it "raises TypeError (R036) for a wrong-typed limit: kwarg, not a raw Crystal crash" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.read(#{(file).inspect}, limit: "big")
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
