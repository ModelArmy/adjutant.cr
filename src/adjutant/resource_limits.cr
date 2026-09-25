module Adjutant
  # Per-run caps on what a script consumes outside the VM: bytes read
  # and written, seconds elapsed, streams held open. Breaching a budget
  # raises an unrescuable FatalSignal, unlike ExecutionLimits (vm.cr),
  # whose instruction and depth limits raise a catchable RuntimeError.
  # Every budget is nil, meaning not enforced, unless set.
  class ResourceLimits
    # How many stream sources may be open at once. A cap on what is
    # held, not a cumulative budget, so breaching it is recoverable
    # (`Legate::TooMany`): closing a stream frees a slot. Without it a
    # leaking script fails at the process's fd limit, with an opaque
    # error.
    DEFAULT_MAX_OPEN_STREAMS = 64

    getter max_open_streams : Int32

    # For whatever sets up OS-level enforcement (cgroups, rlimit);
    # `Budget` doesn't track it.
    getter memory : Int64?

    getter wall_clock : Int32?
    getter total_read : Int64?
    getter total_write : Int64?

    def initialize(@max_open_streams = DEFAULT_MAX_OPEN_STREAMS,
                   @memory = nil, @wall_clock = nil,
                   @total_read = nil, @total_write = nil)
    end
  end
end
