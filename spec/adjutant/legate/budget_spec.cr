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

module Adjutant
  # Same Legate.read-shaped trigger broker_spec.cr already
  # established — real Broker#authorize_read + real File.read, not a
  # stub. Duplicated locally (rather than shared) since spec files in
  # this codebase are self-contained; see broker_spec.cr's own
  # comment on why this shape was chosen over a synthetic trigger.
  private def self.interp_with_read_trigger(broker : Legate::Broker) : Interpreter
    interp, _ = make_interp
    interp.modules.register("test/legate_budget_read_trigger") do |i|
      i.define_native("legate_read_trigger") do |args, _blk, ncc|
        path = args[0].as_string
        broker.authorize_read(path, ncc)
        content = File.read(path)
        broker.budget.record_read(content.bytesize.to_i64)
        Value.string(content)
      end
    end
    interp.modules.require("test/legate_budget_read_trigger", interp)
    interp
  end

  describe Legate::Budget do
    describe "#record_read / #record_write" do
      it "accumulates across calls" do
        budget = Legate::Budget.new(Legate::Limits.new)
        budget.record_read(100_i64)
        budget.record_read(50_i64)
        budget.total_read.should eq 150_i64
      end

      it "does not raise when total_read has no configured limit" do
        budget = Legate::Budget.new(Legate::Limits.new)
        budget.record_read(1_000_000_i64)
      end

      it "raises FatalSignal :exhausted the moment the cumulative total exceeds total_read" do
        limits = Legate::Limits.new(total_read: 100_i64)
        budget = Legate::Budget.new(limits)
        budget.record_read(60_i64)
        expect_raises(Legate::FatalSignal, /total_read budget exceeded/) do
          budget.record_read(60_i64)
        end
        budget.total_read.should eq 120_i64
      end

      it "raises with kind :exhausted specifically" do
        limits = Legate::Limits.new(total_read: 10_i64)
        budget = Legate::Budget.new(limits)
        begin
          budget.record_read(20_i64)
          fail "expected a FatalSignal"
        rescue ex : Legate::FatalSignal
          ex.kind.should eq :exhausted
        end
      end

      it "tracks total_write independently of total_read" do
        limits = Legate::Limits.new(total_read: 10_i64, total_write: 1_000_i64)
        budget = Legate::Budget.new(limits)
        expect_raises(Legate::FatalSignal, /total_read/) do
          budget.record_read(20_i64)
        end
        budget.record_write(500_i64)
        budget.total_write.should eq 500_i64
      end
    end

    describe "#check_wall_clock!" do
      it "does not raise when wall_clock is not enforced" do
        Legate::Budget.new(Legate::Limits.new(wall_clock: nil)).check_wall_clock!
      end

      it "raises FatalSignal :exhausted once the configured wall_clock has elapsed" do
        limits = Legate::Limits.new(wall_clock: 0)
        budget = Legate::Budget.new(limits)
        sleep 10.milliseconds
        expect_raises(Legate::FatalSignal, /wall_clock budget exceeded/) do
          budget.check_wall_clock!
        end
      end

      it "does not raise before the configured wall_clock has elapsed" do
        limits = Legate::Limits.new(wall_clock: 300)
        Legate::Budget.new(limits).check_wall_clock!
      end
    end

    describe "#start_run!" do
      it "zeroes the counts and restarts the clock" do
        budget = Legate::Budget.new(Legate::Limits.new(wall_clock: 1))
        budget.record_read(5_i64)
        budget.record_write(7_i64)
        sleep 1.1.seconds
        budget.start_run!
        budget.total_read.should eq 0
        budget.total_write.should eq 0
        budget.check_wall_clock!
      end
    end

    # Per-run means per `eval`: a long-lived Interpreter must not spend
    # one budget across every script it runs.
    describe "across runs of one Interpreter" do
      it "gives each eval the whole total_read budget" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "12345678")
          grants = Legate::Grants.new(read_roots: [dir], limits: Legate::Limits.new(total_read: 10_i64))
          interp, _ = make_interp(grants: grants)
          2.times do
            interp.eval(%(Legate.read(#{file.inspect}))).as_string.should eq "12345678"
          end
        end
      end
    end

    # `require` of a VFS file runs inside the current run; were it a
    # run of its own, a script could reset its budgets by requiring
    # a file, and pull its streams and scratch out from under itself.
    describe "require inside a run" do
      it "does not reset the budget" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "12345678")
          grants = Legate::Grants.new(read_roots: [dir], limits: Legate::Limits.new(total_read: 10_i64))
          interp, ef = make_interp(grants: grants)
          ef.add_file("helper", "1")
          expect_raises(Legate::FatalSignal, /total_read budget exceeded/) do
            interp.eval(%(Legate.read(#{file.inspect})\nrequire "helper"\nLegate.read(#{file.inspect})))
          end
        end
      end

      it "keeps the run's scratch directory" do
        interp, ef = make_interp(grants: Legate::Grants.deny_all)
        ef.add_file("helper", "1")
        result = interp.eval(%(before = Legate.scratch.to_s\nrequire "helper"\nbefore == Legate.scratch.to_s))
        result.truthy?.should be_true
      end
    end

    # Without the VM's own check, a loop with no effects never meets
    # the wall clock.
    describe "wall_clock and pure computation" do
      it "ends a loop that makes no effectful calls" do
        grants = Legate::Grants.new(limits: Legate::Limits.new(wall_clock: 1))
        interp, _ = make_interp(grants: grants)
        expect_raises(Legate::FatalSignal, /wall_clock budget exceeded/) do
          interp.eval("x = 0\nwhile true\n  x += 1\nend")
        end
      end
    end
  end

  describe Legate::AuditLog do
    it "starts empty" do
      Legate::AuditLog.new.records.should be_empty
    end

    it "appends in call order" do
      log = Legate::AuditLog.new
      log.append(Legate::AuditRecord.new("read", "/a", Authority::Read, :allowed))
      log.append(Legate::AuditRecord.new("write", "/b", Authority::Write, :denied))
      log.records.map(&.verb).should eq ["read", "write"]
    end
  end

  describe "Legate::Broker — Budget and AuditLog integration" do
    it "appends an :allowed record with no exception_class on a successful read" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello")
        broker = Legate::Broker.new(Legate::Grants.new(read_roots: [dir]))
        interp = interp_with_read_trigger(broker)
        interp.eval(%(legate_read_trigger(#{(file).inspect})))

        record = broker.audit_log.records.last
        record.verb.should eq "read"
        record.authority.should eq Authority::Read
        record.decision.should eq :allowed
        record.exception_class.should be_nil
        record.subject.should eq ::Path.new(File.realpath(file)).to_posix.to_s
      end
    end

    it "appends a :denied record with exception_class Legate::Denied when Grants refuses" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          file = File.join(other, "f.txt")
          File.write(file, "hello")
          broker = Legate::Broker.new(Legate::Grants.new(read_roots: [dir]))
          interp = interp_with_read_trigger(broker)
          expect_raises(Legate::FatalSignal) { interp.eval(%(legate_read_trigger(#{(file).inspect}))) }

          record = broker.audit_log.records.last
          record.decision.should eq :denied
          record.exception_class.should eq "Legate::Denied"
        end
      end
    end

    it "appends a :rejected record with exception_class RiskFlowRejectedError when RiskFlowPolicy refuses after Grants passed" do
      with_tmpdir do |dir|
        file = File.join(dir, "secret.txt")
        File.write(file, "hello")
        grants = Legate::Grants.new(read_roots: [dir])
        broker = Legate::Broker.new(grants)
        policy = RiskFlowPolicy.new(
          sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::File, file, 10, Sensitivity::High)],
          reject_all_flows: true,
        )
        interp, _ = make_interp(risk_flow_policy: policy)
        interp.modules.register("test/legate_budget_reject_trigger") do |i|
          i.define_native("legate_read_trigger") do |args, _blk, ncc|
            path = args[0].as_string
            broker.authorize_read(path, ncc)
            Value.string(File.read(path))
          end
        end
        interp.modules.require("test/legate_budget_reject_trigger", interp)

        interp.eval(<<-RUBY)
        begin
          legate_read_trigger(#{(file).inspect})
        rescue
          "swallowed"
        end
        RUBY

        record = broker.audit_log.records.last
        record.decision.should eq :rejected
        record.exception_class.should eq "RiskFlowRejectedError"
      end
    end

    it "checks wall_clock before Grants — a run-length exhaustion pre-empts an otherwise-allowed read" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hello")
        budget = Legate::Budget.new(Legate::Limits.new(wall_clock: 0))
        broker = Legate::Broker.new(Legate::Grants.new(read_roots: [dir]), budget: budget)
        interp = interp_with_read_trigger(broker)
        sleep 10.milliseconds
        expect_raises(Legate::FatalSignal, /wall_clock/) do
          interp.eval(%(legate_read_trigger(#{(file).inspect})))
        end
      end
    end

    it "a shared Budget accumulates total_read across repeated calls until exhaustion" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "0123456789") # 10 bytes
        budget = Legate::Budget.new(Legate::Limits.new(total_read: 25_i64))
        broker = Legate::Broker.new(Legate::Grants.new(read_roots: [dir]), budget: budget)
        interp = interp_with_read_trigger(broker)

        interp.eval(%(legate_read_trigger(#{(file).inspect}))) # 10
        interp.eval(%(legate_read_trigger(#{(file).inspect}))) # 20
        expect_raises(Legate::FatalSignal, /total_read budget exceeded/) do
          interp.eval(%(legate_read_trigger(#{(file).inspect}))) # 30 > 25
        end
        budget.total_read.should eq 30_i64
      end
    end
  end
end
