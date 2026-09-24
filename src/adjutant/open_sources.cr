require "./resource_limits"

module Adjutant
  # A stream source holding an OS resource for one walk: an open file
  # or an HTTP connection. It registers with the run's `OpenSources`
  # when built, closes itself when exhausted, and is otherwise closed
  # by `OpenSources#close_all` at the end of the run. Halting a walk
  # must not close it, since sibling streams may share its position;
  # see DEVELOPMENT.md, "Stream sources and `OpenSources`".
  module Closable
    # Must be idempotent: `close_all` doesn't know whether the source
    # already closed itself.
    abstract def close_source : Nil
  end

  # The stream sources opened during one run and not yet closed.
  # `Interpreter#eval` calls `close_all` when the run ends, raised or
  # not.
  class OpenSources
    # From `ResourceLimits#max_open_streams`.
    getter max_open : Int32

    def initialize(@max_open : Int32 = ResourceLimits::DEFAULT_MAX_OPEN_STREAMS)
      @open = [] of Closable
    end

    # Whether one more source would exceed the cap. A predicate, so
    # this class needs no interpreter; `Broker#register_source` raises.
    def at_capacity? : Bool
      @open.size >= @max_open
    end

    # How many sources are open.
    def size : Int32
      @open.size
    end

    def register(source : Closable) : Nil
      @open << source
    end

    # Deregisters a source that closed itself. Compared by identity:
    # two iterators over one path are two resources.
    def release(source : Closable) : Nil
      @open.reject!(&.same?(source))
    end

    # Closes every source still open, in reverse order of
    # registration, so a wrapper closes before what it wraps. Returns
    # the exceptions any close raised instead of raising them, since
    # this runs in an `ensure` and must not replace the script's own
    # error.
    def close_all : Array(Exception)
      # Taken and cleared first: each `close_source` calls `release`,
      # which would otherwise modify `@open` during iteration.
      pending = @open.dup
      @open.clear

      failures = [] of Exception
      pending.reverse_each do |source|
        source.close_source
      rescue ex
        failures << ex
      end
      failures
    end
  end
end
