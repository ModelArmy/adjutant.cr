module Adjutant
  # Per-run caps on what a script consumes outside the VM: bytes read
  # and written, seconds elapsed, streams held open. Breaching a budget
  # raises an unrescuable FatalSignal, unlike ExecutionLimits (vm.cr),
  # whose instruction and depth limits raise a catchable RuntimeError.
  # Every budget has a default (LEGATE.md §7), so a policy that names
  # none still bounds a run. Nil, which only code can pass, means not
  # enforced.
  class ResourceLimits
    # How many stream sources may be open at once. A cap on what is
    # held, not a cumulative budget, so breaching it is recoverable
    # (`Legate::TooMany`): closing a stream frees a slot. Without it a
    # leaking script fails at the process's fd limit, with an opaque
    # error.
    DEFAULT_MAX_OPEN_STREAMS = 64

    getter max_open_streams : Int32

    DEFAULT_MEMORY      =   536_870_912_i64 # 512 MiB
    DEFAULT_WALL_CLOCK  =               300 # seconds
    DEFAULT_TOTAL_READ  = 4_294_967_296_i64 # 4 GiB
    DEFAULT_TOTAL_WRITE = 1_073_741_824_i64 # 1 GiB

    # For whatever sets up OS-level enforcement (cgroups, rlimit);
    # `Budget` doesn't track it, so its default is advice to the host.
    getter memory : Int64?

    getter wall_clock : Int32?
    getter total_read : Int64?
    getter total_write : Int64?

    def initialize(@max_open_streams = DEFAULT_MAX_OPEN_STREAMS,
                   @memory : Int64? = DEFAULT_MEMORY, @wall_clock : Int32? = DEFAULT_WALL_CLOCK,
                   @total_read : Int64? = DEFAULT_TOTAL_READ, @total_write : Int64? = DEFAULT_TOTAL_WRITE)
    end
  end
end
