require "../spec_helper"

module Adjutant
  # A FatalSignal raised by something that is NOT Legate. The point of
  # promoting FatalSignal to core (2026-09-01) is that any subsystem
  # enforcing its own limits can raise one and have it unwind
  # correctly; nothing exercised that, because every existing fatal
  # spec raises `Legate::FatalSignal`, which is now an ALIAS for the
  # core class — so those specs pass identically whichever type
  # `call_native` rescues, and cannot tell the promotion happened.
  #
  # A subclass can. `call_native`'s clause has to match this
  # polymorphically for a future subsystem's own signal to reach past
  # the script's rescue machinery.
  private class SyntheticSubsystemSignal < FatalSignal
  end

  # Module-level (not nested inside a `describe` block) since `def
  # self.foo` inside a block defines on whatever `self` the block runs
  # with, not the enclosing module — same reasoning as
  # spec_helper.cr's own helpers.
  private def self.interp_raising(ex : Exception) : Interpreter
    interp, _ = make_interp
    interp.modules.register("test/core_fatal_trigger") do |i|
      i.define_native("trigger_fatal") do |_args, _blk, _ncc|
        raise ex
      end
    end
    interp.modules.require("test/core_fatal_trigger", interp)
    interp
  end

  describe "core run accounting" do
    describe "ResourceLimits" do
      # Goes red if the default is changed, or if Legate::Limits stops
      # chaining to super and reintroduces a local constant that
      # drifts from core's. Nothing asserted this before the constant
      # moved out of Legate::Limits.
      it "defaults max_open_streams to 64, and Legate::Limits inherits that default rather than defining its own" do
        ResourceLimits.new.max_open_streams.should eq 64
        Legate::Limits.new.max_open_streams.should eq ResourceLimits.new.max_open_streams
      end

      # The per-run budgets are unenforced-when-absent, not zero —
      # the posture ResourceLimits' own comment records. A default of
      # 0 would silently mean "no bytes may be read at all".
      it "leaves every per-run budget nil by default" do
        limits = ResourceLimits.new
        limits.wall_clock.should be_nil
        limits.total_read.should be_nil
        limits.total_write.should be_nil
        limits.memory.should be_nil
      end

      # Legate's own per-call caps still arrive through the subclass —
      # goes red if the split dropped one on the floor.
      it "Legate::Limits still carries its per-call caps alongside the inherited run budgets" do
        limits = Legate::Limits.new(read_limit: 99_i64, total_read: 100_i64)
        limits.read_limit.should eq 99_i64
        limits.total_read.should eq 100_i64
      end
    end

    describe "Budget" do
      # Constructed from a plain core ResourceLimits with no Legate
      # anywhere in sight. Goes red if Budget reacquires a dependency
      # on Legate::Limits, which is the thing the promotion was for.
      it "enforces total_read against a core ResourceLimits, with no Legate types involved" do
        budget = Budget.new(ResourceLimits.new(total_read: 10_i64))
        budget.record_read(4_i64)
        budget.total_read.should eq 4_i64

        ex = expect_raises(FatalSignal, /total_read budget exceeded/) do
          budget.record_read(7_i64)
        end
        ex.kind.should eq :exhausted
      end

      # The counting-then-checking order: the call that crosses the
      # limit is itself the one that raises, and the total it reports
      # includes those bytes. Goes red if the check moves before the
      # increment.
      it "counts the bytes that breached the limit before raising" do
        budget = Budget.new(ResourceLimits.new(total_write: 5_i64))
        expect_raises(FatalSignal, /6bytes > 5bytes/) do
          budget.record_write(6_i64)
        end
        budget.total_write.should eq 6_i64
      end
    end

    describe "FatalSignal" do
      # THE contract documented on FatalSignal: a subsystem's own
      # signal only unwinds if it IS a FatalSignal. Goes red if
      # call_native's clause is narrowed to an exact class, or removed
      # so the catch-all below flattens it into a script-catchable
      # N001.
      it "a subclass raised by a non-Legate native still propagates past rescue Exception" do
        interp = interp_raising(SyntheticSubsystemSignal.new(:exhausted, "synthetic subsystem limit"))
        expect_raises(SyntheticSubsystemSignal, /synthetic subsystem limit/) do
          interp.eval(<<-RUBY)
          begin
            trigger_fatal
          rescue Exception => e
            "swallowed"
          end
          RUBY
        end
      end

      # The negative half: an ordinary Crystal exception from a native
      # is NOT fatal — it flattens into something a script can rescue.
      # Without this, the spec above would pass just as well if
      # EVERYTHING escaped the rescue machinery, which would be a far
      # worse bug than the one it guards.
      it "an ordinary exception from a native is still catchable, so the case above is about FatalSignal specifically" do
        interp = interp_raising(Exception.new("ordinary native failure"))
        interp.eval(<<-RUBY).as_string.should eq "swallowed"
        begin
          trigger_fatal
        rescue Exception => e
          "swallowed"
        end
        RUBY
      end
    end
  end
end
