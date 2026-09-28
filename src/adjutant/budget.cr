require "./resource_limits"
require "./fatal_signal"

module Adjutant
  # Per-run cumulative budgets: bytes read and written, and elapsed
  # time. The middle of three tiers: per-call limits live with each
  # call, and memory, CPU and descriptors with the OS. `memory` isn't
  # tracked here. The counts and the wall clock start when the Budget
  # is built, and again at each `start_run!`, which `Interpreter#eval`
  # calls, so each run gets the whole budget.
  class Budget
    getter total_read : Int64
    getter total_write : Int64

    def initialize(@limits : ResourceLimits)
      @total_read = 0_i64
      @total_write = 0_i64
      @started_at = Time.instant
    end

    # Starts a new run: counts back to zero, and the clock from now.
    def start_run! : Nil
      @total_read = 0_i64
      @total_write = 0_i64
      @started_at = Time.instant
    end

    # Counts `n` bytes after they have moved, then checks, so the call
    # that crosses the budget is the one that raises.
    def record_read(n : Int64) : Nil
      @total_read += n
      return unless limit = @limits.total_read
      exhausted!("total_read", @total_read, limit, "bytes") if @total_read > limit
    end

    def record_write(n : Int64) : Nil
      @total_write += n
      return unless limit = @limits.total_write
      exhausted!("total_write", @total_write, limit, "bytes") if @total_write > limit
    end

    # Checked at the start of each authorization and, every
    # `VM::WALL_CLOCK_INTERVAL` instructions, by the VM, so pure
    # computation meets it too.
    def check_wall_clock! : Nil
      return unless limit = @limits.wall_clock
      elapsed = (Time.instant - @started_at).total_seconds
      exhausted!("wall_clock", elapsed.round(1), limit, "s") if elapsed > limit
    end

    private def exhausted!(name : String, actual, limit, unit : String) : NoReturn
      raise FatalSignal.new(:exhausted, "#{name} budget exceeded (#{actual}#{unit} > #{limit}#{unit})")
    end
  end
end
