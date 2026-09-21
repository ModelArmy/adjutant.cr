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

# `Legate::Path` renders consistently POSIX-style (`/`-separated) on
# every platform BY DESIGN (path.cr's own comment; mkdir.cr's own
# `::Path.new(...).to_posix` before constructing its returned Path) —
# a real, correct difference from `File.join`'s NATIVE-separator
# output (`\`-joined on Windows). Same helper as list_spec.cr/
# grep_spec.cr's own identical one, for the same reason.
private def posix(path : String) : String
  ::Path.new(path).to_posix.to_s
end

module Adjutant
  describe "Legate.mkdir" do
    it "creates a single new directory and returns its Path" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(%(Legate.mkdir(#{(target).inspect}).to_s))
        eval.as_string.should eq posix(target)
        File.directory?(target).should be_true
      end
    end

    it "creates every missing intermediate directory (always recursive)" do
      with_tmpdir do |dir|
        target = File.join(dir, "a", "b", "c")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.mkdir(#{(target).inspect})))
        File.directory?(target).should be_true
      end
    end

    it "succeeds (idempotent) when the directory already exists" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.mkdir(#{(target).inspect})
          "no error"
        rescue
          "errored"
        end
        RUBY
        eval.as_string.should eq "no error"
      end
    end

    it "raises Legate::Conflict when a FILE already exists at that path" do
      with_tmpdir do |dir|
        target = File.join(dir, "f.txt")
        File.write(target, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.mkdir(#{(target).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "denies with a FatalSignal for a path outside every granted write root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
            interp.eval(%(Legate.mkdir(#{(File.join(other, "sub")).inspect})))
          end
        end
      end
    end

    it "denies with no write grant at all" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.write denied/) do
          interp.eval(%(Legate.mkdir(#{(File.join(dir, "sub")).inspect})))
        end
      end
    end

    it "logs exactly one :allowed audit record per invocation" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        interp.eval(%(Legate.mkdir(#{(target).inspect})))
        records = interp.broker.audit_log.records.select { |r| r.verb == "write" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end
  end
end
