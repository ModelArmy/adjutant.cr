require "./grants"
require "./exceptions"

module Adjutant
  module Legate
    # Per-run cumulative budget tracking — LEGATE.md §7's "per-run
    # budgets are fatal" and §8.4's three-tier enforcement ("per-call
    # limits in the verb; per-run budgets in the broker; memory, CPU
    # and file descriptors at the OS via cgroups or rlimit"). This
    # class is the MIDDLE tier only.
    #
    # `memory` is deliberately NOT tracked here, even though §7 lists
    # it alongside `wall_clock`/`total_read`/`total_write` — §8.4
    # explicitly assigns memory (and CPU, and fd count) to the OS
    # tier, and Crystal has no portable, dependency-free way to read
    # a process's own live RSS to begin with. Reimplementing an
    # approximation here would be the wrong layer doing the OS's job
    # imprecisely; an embedder wanting `memory` enforced applies it
    # via cgroups/rlimit around the whole run, outside Adjutant
    # entirely. `Limits#memory` still exists (grants.cr) purely so a
    # policy file can state the number for whatever's setting up that
    # OS-level enforcement to read — Budget just doesn't consume it.
    #
    # One Budget per run, started at construction — `wall_clock`
    # counts from when the broker (and therefore this) is built, not
    # from the first verb call, matching "per run" rather than
    # "per active verb time."
    class Budget
      getter total_read : Int64
      getter total_write : Int64

      def initialize(@limits : Limits)
        @total_read = 0_i64
        @total_write = 0_i64
        @started_at = Time.instant
      end

      # Called by a VERB (step 5), after it has actually moved `n`
      # bytes off disk — NOT by the broker's own authorize_read,
      # which runs BEFORE the read happens and has no byte count yet
      # to add. `n` is counted first, then checked — so a call that
      # pushes the total over the limit is itself the one that raises
      # (consistent with "hitting the budget is exhaustion," not
      # "the call after the one that hit it").
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

      # Checked opportunistically at the START of every broker
      # authorize_* call (see broker.cr) rather than via a background
      # timer — Adjutant has no other need for a timer thread, and a
      # script that's been running long between verb calls is caught
      # at its NEXT one, which is the only point a fatal signal could
      # meaningfully interrupt script execution anyway.
      def check_wall_clock! : Nil
        return unless limit = @limits.wall_clock
        elapsed = (Time.instant - @started_at).total_seconds
        exhausted!("wall_clock", elapsed.round(1), limit, "s") if elapsed > limit
      end

      private def exhausted!(name : String, actual, limit, unit : String) : NoReturn
        raise FatalSignal.new(:exhausted, "Legate: #{name} budget exceeded (#{actual}#{unit} > #{limit}#{unit})")
      end
    end
  end
end
