module Adjutant
  # Per-run ceilings on what a script may consume from OUTSIDE the VM:
  # bytes read, bytes written, seconds elapsed, handles held open.
  #
  # Distinct from `ExecutionLimits` (vm.cr), which bounds the VM's own
  # computation — instructions executed and call depth. The two are the
  # same category of thing (per-run ceilings an embedder configures
  # once) but NOT the same contract, and that is why they are separate
  # types rather than one:
  #
  #   - Breaching an ExecutionLimits bound raises a script-CATCHABLE
  #     RuntimeError (L002/L004).
  #   - Breaching one of these raises an UNRESCUABLE FatalSignal.
  #
  # Merging them would put rescuable and fatal semantics behind a
  # single name. See SCOPE.md for the conditions under which they
  # could later be unified.
  #
  # Every field here is nilable and defaults to nil except
  # `max_open_streams`: an unset budget means UNENFORCED, not zero. The
  # alternative (treat an omitted budget as an error, or as some
  # implicit cap) is defensible too; this is the posture chosen.
  class ResourceLimits
    # A cap on how many stream-backing sources may be held open AT
    # ONCE. Not a cumulative budget: `OpenSources#close_all` bounds a
    # leak in TIME but not in COUNT — a script looping over ten
    # thousand paths and abandoning each stream after one element
    # holds ten thousand descriptors simultaneously, every one of them
    # released only when the run ends. Without a cap that fails at
    # whatever the process fd limit happens to be, as an opaque `Too
    # many open files` from somewhere deep inside `File.open`.
    #
    # Because it caps SIMULTANEOUS HOLDINGS rather than cumulative
    # consumption, breaching it is RECOVERABLE rather than fatal — a
    # script that hits it and then finishes walking one stream has
    # genuinely freed the resource, so retrying is legitimate rather
    # than an end-run around exhaustion. It is therefore the one
    # member here whose enforcement is not a FatalSignal; the raising
    # wrapper lives with whoever owns the registry.
    #
    # 64 by default: far above any plausible legitimate fan-out (a
    # script comparing a handful of files, or fetching a few endpoints
    # in sequence, holds one or two), and far below any ordinary
    # process fd limit, so the cap bites long before the OS does and
    # says something useful when it does.
    DEFAULT_MAX_OPEN_STREAMS = 64

    getter max_open_streams : Int32

    # Stated for whatever sets up OS-level enforcement to read, NOT
    # consumed by `Budget`. Memory (and CPU, and fd count) belong to
    # the OS tier via cgroups or rlimit around the whole run: Crystal
    # has no portable, dependency-free way to read a process's own
    # live RSS, and approximating one here would be the wrong layer
    # doing the OS's job imprecisely.
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
