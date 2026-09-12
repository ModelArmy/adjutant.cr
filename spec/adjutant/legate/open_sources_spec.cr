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

# A `Closable` with no real resource behind it — the registry's own
# contract (register/release/close_all, idempotence, failure
# isolation) is verifiable without opening a file at all, and doing it
# this way keeps these cases from depending on any verb's behaviour.
private class FakeSource
  include Adjutant::Legate::Closable

  getter closes : Int32 = 0

  def initialize(@raises : Bool = false)
  end

  def close_source : Nil
    @closes += 1
    raise IO::Error.new("cannot close") if @raises
  end
end

# Deregisters itself on close, exactly as every real iterator does —
# the shape that broke `close_all` when it iterated the live array.
private class SelfReleasingSource
  include Adjutant::Legate::Closable

  getter closes : Int32 = 0

  def initialize(@registry : Adjutant::Legate::OpenSources)
  end

  def close_source : Nil
    @closes += 1
    @registry.release(self)
  end
end

module Adjutant
  describe Legate::OpenSources do
    it "closes everything still registered" do
      registry = Legate::OpenSources.new
      a = FakeSource.new
      b = FakeSource.new
      registry.register(a)
      registry.register(b)

      registry.close_all.should be_empty
      a.closes.should eq 1
      b.closes.should eq 1
      registry.size.should eq 0
    end

    it "does not close a source that already released itself" do
      registry = Legate::OpenSources.new
      a = FakeSource.new
      registry.register(a)
      registry.release(a)

      registry.close_all
      a.closes.should eq 0
    end

    # Identity, not equality — two iterators over the same path are
    # two distinct handles, and releasing one must not deregister the
    # other.
    it "releases only the identical source, not an equal one" do
      registry = Legate::OpenSources.new
      a = FakeSource.new
      b = FakeSource.new
      registry.register(a)
      registry.register(b)
      registry.release(a)

      registry.size.should eq 1
      registry.close_all
      a.closes.should eq 0
      b.closes.should eq 1
    end

    # `close_all` runs from an `ensure`, frequently while a real
    # exception is unwinding — one failing close must not strand the
    # rest, and must not replace the script's own error.
    it "closes every source even when one raises, collecting failures" do
      registry = Legate::OpenSources.new
      good_first = FakeSource.new
      bad = FakeSource.new(raises: true)
      good_last = FakeSource.new
      registry.register(good_first)
      registry.register(bad)
      registry.register(good_last)

      failures = registry.close_all

      failures.size.should eq 1
      good_first.closes.should eq 1
      good_last.closes.should eq 1
      registry.size.should eq 0
    end

    # REGRESSION. `close_all` used to iterate `@open` directly while
    # each `close_source` called `release` on it — mutating the array
    # mid-iteration and skipping entries. Every real iterator
    # self-releases, so this is the ordinary case, not an exotic one.
    # Ten sources rather than two or three: a mid-iteration skip can
    # pass by luck on a short list.
    it "closes every source even when each releases itself while closing" do
      registry = Legate::OpenSources.new
      sources = Array.new(10) { SelfReleasingSource.new(registry) }
      sources.each { |source| registry.register(source) }

      registry.close_all.should be_empty
      sources.each(&.closes.should(eq 1))
      registry.size.should eq 0
    end

    it "is empty after close_all, so a second call is a no-op" do
      registry = Legate::OpenSources.new
      a = FakeSource.new
      registry.register(a)

      registry.close_all
      registry.close_all
      a.closes.should eq 1
    end

    it "reports capacity against its configured cap" do
      registry = Legate::OpenSources.new(2)
      registry.at_capacity?.should be_false
      registry.register(FakeSource.new)
      registry.at_capacity?.should be_false
      registry.register(FakeSource.new)
      registry.at_capacity?.should be_true
    end

    it "is below capacity again once a source releases" do
      registry = Legate::OpenSources.new(1)
      a = FakeSource.new
      registry.register(a)
      registry.at_capacity?.should be_true

      registry.release(a)
      registry.at_capacity?.should be_false
    end
  end

  describe "max_open_streams" do
    it "refuses to open more streams than the cap allows" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(
          grants: Legate::Grants.new(
            read_roots: [dir],
            limits: Legate::Limits.new(max_open_streams: 2),
          ),
        )

        # Three streams opened and none consumed. The third is the one
        # that must fail, and it must fail as a recoverable TooMany the
        # script can see — not as an fd exhaustion from inside File.
        eval = interp.eval(<<-RUBY)
        opened = 0
        error = nil
        begin
          3.times do
            Legate.bytes(#{file.inspect}, chunk: 4)
            opened = opened + 1
          end
        rescue Legate::TooMany => e
          error = e.message
        end
        [opened, error]
        RUBY

        result = eval.as_array.to_a
        result[0].as_int.should eq 2
        result[1].as_string.should contain "2 streams are already open"
      end
    end

    # The cap is on SIMULTANEOUS holdings, not cumulative opens — a
    # script that finishes with one stream can always open another.
    # This is the property that makes the limit recoverable rather
    # than fatal, so it is worth a test of its own.
    it "allows opening again after an earlier stream is fully walked" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(
          grants: Legate::Grants.new(
            read_roots: [dir],
            limits: Legate::Limits.new(max_open_streams: 1),
          ),
        )

        eval = interp.eval(<<-RUBY)
        count = 0
        3.times do
          Legate.bytes(#{file.inspect}, chunk: 4).each { |c| c }
          count = count + 1
        end
        count
        RUBY

        eval.as_int.should eq 3
      end
    end

    # The refusal must happen BEFORE the handle is opened. If it did
    # not, the very call that reports the cap would itself leak a
    # descriptor, and the registry would be the only thing that knew.
    it "leaves nothing registered when it refuses" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(
          grants: Legate::Grants.new(
            read_roots: [dir],
            limits: Legate::Limits.new(max_open_streams: 1),
          ),
        )

        interp.eval(<<-RUBY)
        Legate.bytes(#{file.inspect}, chunk: 4)
        begin
          Legate.bytes(#{file.inspect}, chunk: 4)
        rescue Legate::TooMany => e
          nil
        end
        RUBY

        interp.broker.open_sources.size.should eq 0
      end
    end

    it "applies the same cap to lines and records" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "a\nb\nc\n")
        interp, _ = make_interp(
          grants: Legate::Grants.new(
            read_roots: [dir],
            limits: Legate::Limits.new(max_open_streams: 1),
          ),
        )

        eval = interp.eval(<<-RUBY)
        Legate.lines(#{file.inspect})
        caught = false
        begin
          Legate.lines(#{file.inspect})
        rescue Legate::TooMany => e
          caught = true
        end
        caught
        RUBY

        eval.truthy?.should be_true
      end
    end
  end

  describe "stream source lifetime" do
    # The ordinary path, unchanged by this work: a fully-walked stream
    # closes itself and leaves nothing for teardown.
    it "deregisters a stream walked to exhaustion" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.bytes(#{file.inspect}, chunk: 4).to_a))

        interp.broker.open_sources.size.should eq 0
      end
    end

    # The case this whole registry exists for. `first(1)` halts the
    # walk without exhausting the source, so the iterator's own
    # close-on-exhaustion is never reached — before teardown existed
    # this leaked a file descriptor silently.
    it "closes a stream abandoned by first(n)" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.bytes(#{file.inspect}, chunk: 4).first(1)))

        interp.broker.open_sources.size.should eq 0
      end
    end

    # The second uncovered exit: an exception leaving the walk
    # entirely. The `ensure` is what makes this work, so the raise
    # must genuinely propagate AND the handle still be released.
    it "closes a stream whose walk raised" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))

        expect_raises(Exception) do
          interp.eval(<<-RUBY)
          Legate.bytes(#{file.inspect}, chunk: 4).each { |c| raise "boom" }
          RUBY
        end

        interp.broker.open_sources.size.should eq 0
      end
    end

    it "closes an abandoned lines stream" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "a\nb\nc\nd\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.lines(#{file.inspect}).first(1)))

        interp.broker.open_sources.size.should eq 0
      end
    end

    it "closes an abandoned jsonl records stream" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.jsonl")
        File.write(file, %({"a":1}\n{"a":2}\n{"a":3}\n))
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.records(#{file.inspect}, format: :jsonl).first(1)))

        interp.broker.open_sources.size.should eq 0
      end
    end

    it "closes an abandoned csv records stream" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.csv")
        File.write(file, "a,b\n1,2\n3,4\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.records(#{file.inspect}, format: :csv).first(1)))

        interp.broker.open_sources.size.should eq 0
      end
    end

    # Teardown is scoped to one `eval`, not to the process — a second
    # script on the same Interpreter must start with a clean registry
    # rather than inheriting the first one's open handles.
    it "starts each eval with nothing left over from the last" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))

        interp.eval(%(Legate.bytes(#{file.inspect}, chunk: 4).first(1)))
        interp.broker.open_sources.size.should eq 0

        interp.eval(%(Legate.bytes(#{file.inspect}, chunk: 4).first(1)))
        interp.broker.open_sources.size.should eq 0
      end
    end

    # Idempotence in the shape it actually occurs: teardown closes an
    # abandoned stream, and nothing about a subsequent pull should
    # reach a closed handle.
    it "leaves an abandoned stream safe to pull again after teardown" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.bytes(#{file.inspect}, chunk: 4).first(1)))

        # Second close via the registry's own path must not raise.
        interp.broker.open_sources.close_all.should be_empty
      end
    end
  end
end
