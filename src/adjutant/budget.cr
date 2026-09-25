require "./resource_limits"
require "./fatal_signal"

module Adjutant
  # Per-run cumulative budgets: bytes read and written, and elapsed
  # time. The middle of three tiers: per-call limits live with each
  # call, and memory, CPU and descriptors with the OS. `memory` isn't
  # tracked here. The wall clock starts when the Budget is built,
  # which is when the run starts.
  class Budget
    getter total_read : Int64
    getter total_write : Int64

    def initialize(@limits : ResourceLimits)
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

    # Checked at the start of each authorization, with no timer, so a
    # script that makes no effectful calls is never checked.
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
