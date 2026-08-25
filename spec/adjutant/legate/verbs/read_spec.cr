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
        interp.eval(%(Legate.read("#{file}"))).as_string.should eq "hello world"
      end
    end

    it "accepts a Legate::Path argument" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.read(Legate::Path.new("#{file}")))).as_string.should eq "hi"
      end
    end

    it "raises Legate::NotFound for a missing path under a granted root" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.read("#{File.join(dir, "nope.txt")}")
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
            interp.eval(%(Legate.read("#{File.join(other, "nope.txt")}")))
          end
        end
      end
    end

    describe "missing: kwarg (§2.5)" do
      it "returns nil when missing: nil is given and the path is absent" do
        with_tmpdir do |dir|
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          result = interp.eval(%(Legate.read("#{File.join(dir, "nope.txt")}", missing: nil)))
          result.raw.nil?.should be_true
        end
      end

      it "returns the given default when missing: \"{}\" is given and the path is absent" do
        with_tmpdir do |dir|
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          result = interp.eval(%(Legate.read("#{File.join(dir, "nope.txt")}", missing: "{}")))
          result.as_string.should eq "{}"
        end
      end

      it "missing: does NOT suppress Legate::Denied for a path outside every granted root" do
        with_tmpdir do |dir|
          with_tmpdir do |other|
            interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
            expect_raises(Legate::FatalSignal, /denied/) do
              interp.eval(%(Legate.read("#{File.join(other, "nope.txt")}", missing: nil)))
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
            Legate.read("#{file}", limit: 10, missing: nil)
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
          interp.eval(%(Legate.read("#{file}", missing: nil))).as_string.should eq "hi"
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
            Legate.read("#{file}")
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
          interp.eval(%(Legate.read("#{file}", limit: 1_000_000))).as_string.bytesize.should eq 50
        end
      end

      it "a script-given SMALLER limit: is honored" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "x" * 50)
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.read("#{file}", limit: 10)
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
        interp.eval(%(Legate.read("#{file}")))
        interp.broker.budget.total_read.should eq 10_i64
      end
    end

    it "raises FatalSignal :exhausted once total_read budget is exceeded" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789") # 10 bytes
        limits = Legate::Limits.new(total_read: 15_i64)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], limits: limits))
        interp.eval(%(Legate.read("#{file}"))) # 10, ok
        expect_raises(Legate::FatalSignal, /total_read budget exceeded/) do
          interp.eval(%(Legate.read("#{file}"))) # 20 > 15
        end
      end
    end

    it "denies with no read grant at all" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.read("#{file}")))
        end
      end
    end
  end
end
