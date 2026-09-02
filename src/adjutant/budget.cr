require "./resource_limits"
require "./fatal_signal"

module Adjutant
  # Per-run cumulative budget tracking — the MIDDLE of three
  # enforcement tiers (per-call limits in whatever performs the call;
  # per-run budgets here; memory, CPU and file descriptors at the OS
  # via cgroups or rlimit).
  #
  # `memory` is deliberately NOT tracked here even though
  # `ResourceLimits` carries it — see that field's own comment for why
  # it belongs to the OS tier.
  #
  # One Budget per run, started at construction — `wall_clock` counts
  # from when the budget (and therefore the run) is built, not from the
  # first effectful call, matching "per run" rather than "per active
  # call time."
  #
  # Core rather than Legate as of 2026-09-01: nothing here is
  # verb-shaped. It counts bytes and seconds.
  class Budget
    getter total_read : Int64
    getter total_write : Int64

    def initialize(@limits : ResourceLimits)
      @total_read = 0_i64
      @total_write = 0_i64
      @started_at = Time.instant
    end

    # Called AFTER `n` bytes have actually moved — not by whatever
    # authorized the call, which runs before the read happens and has
    # no byte count yet to add. `n` is counted first, then checked, so
    # a call that pushes the total over the limit is itself the one
    # that raises (consistent with "hitting the budget is exhaustion,"
    # not "the call after the one that hit it").
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

    # Checked opportunistically at the start of every authorization
    # rather than via a background timer — Adjutant has no other need
    # for a timer thread, and a script that has been running long
    # between effectful calls is caught at its NEXT one, which is the
    # only point a fatal signal could meaningfully interrupt script
    # execution anyway.
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
