module Adjutant
  module Legate
    # Anything holding an OS resource (an open `File` today, an
    # `HTTP::Client` once `Legate.fetch stream: true` exists) for the
    # lifetime of ONE stream walk.
    #
    # Every stream-backing `Iterator(Value)` includes this and
    # registers itself with the run's `OpenSources` at construction.
    # Two things then close it, and BOTH must work:
    #
    #   1. The iterator itself, the moment its source is physically
    #      exhausted — the fast, ordinary path, already how every
    #      stream verb behaved before this registry existed.
    #   2. `OpenSources#close_all` at the end of the run, for
    #      everything path 1 never reached.
    #
    # Path 2 exists because path 1 is not reachable in three ordinary
    # cases, none of which are errors:
    #
    #   - ABANDONMENT. `Stream#first(n)`/`take(n)` deliberately
    #     `break` out of `walk` — that is what makes them lazy — so
    #     the source never returns `Iterator::Stop` and the close in
    #     `#next` is never run. `Legate.bytes(p).first(1)` leaks a
    #     file descriptor today; the same shape on a fetch stream
    #     leaks a socket, and a loop over many URLs leaks in
    #     proportion.
    #   - AN EXCEPTION mid-walk (a `TooLarge`, a script error inside a
    #     `.map` block) propagating straight out through `walk`.
    #   - A script that simply stops referring to the stream.
    #
    # WHY NOT just close when the walk halts: LEGATE.md §6.1 blesses
    # sibling streams sharing a pull position (`a = s.select{}; b =
    # s.select{}; a.first(2); b.to_a`), and `stream_spec.cr` tests it.
    # `a.first(2)` halting does NOT mean the source is finished with —
    # `b.to_a` is entitled to keep pulling from wherever it left off.
    # Halt is therefore not a close signal, and cannot be made one
    # without breaking a documented, tested pattern.
    #
    # WHY NOT Crystal's `finalize`: the mechanism exists, but GC
    # timing means "possibly never, before the fd limit is hit," so it
    # cannot be the primary answer; and a finalizer runs at an
    # arbitrary time on an arbitrary thread, where touching the broker,
    # budget or audit log would be actively unsafe. Considered and
    # declined, deliberately — not overlooked.
    module Closable
      # MUST be idempotent. `close_all` cannot know whether an
      # iterator already closed itself on exhaustion, and asking it to
      # track that would duplicate state each iterator already keeps.
      abstract def close_source : Nil
    end

    # Every `Closable` opened during one run, and the seam that closes
    # whatever is left when the run ends.
    #
    # SCOPE IS THE RUN, NOT THE PROCESS. This is deliberately not an
    # `at_exit`-shaped thing: the process is the embedding application
    # and outlives any one script. What is needed is closer to a
    # destructor for a single `eval` — a script that raises must
    # release its sockets so the NEXT script on the same Interpreter
    # starts clean. See `Interpreter#eval`'s own `ensure`.
    class OpenSources
      def initialize
        @open = [] of Closable
      end

      # Currently-open count. Public for specs, and for the per-run
      # open-source cap that lands next — that cap is what makes a
      # script holding thousands of simultaneous streams fail at a
      # knowable number instead of at whatever the OS fd limit
      # happens to be. `close_all` alone bounds the leak in TIME, not
      # in COUNT.
      def size : Int32
        @open.size
      end

      def register(source : Closable) : Nil
        @open << source
      end

      # Called by an iterator that has just closed itself on genuine
      # exhaustion, so `close_all` has nothing left to do for it.
      #
      # Identity comparison (`same?`), not `==`: two distinct
      # iterators over the same path are two distinct resources, and
      # an iterator that defined value equality would otherwise
      # deregister its sibling.
      def release(source : Closable) : Nil
        @open.reject!(&.same?(source))
      end

      # Closes everything still open, in reverse order of
      # registration.
      #
      # Reverse order because a wrapping source may hold a wrapped one
      # (`records`' `:jsonl` path wraps a `LineIterator`), and closing
      # outermost-first is the order that stays correct if a wrapper
      # ever needs its inner source alive to shut down cleanly.
      # Nothing depends on it today; it costs nothing and removes a
      # question a future reader would otherwise have to answer.
      #
      # ONE SOURCE FAILING TO CLOSE MUST NOT STRAND THE REST. A close
      # can genuinely raise (a socket whose peer vanished, an
      # `IO::Error` on a file already closed underneath us), and this
      # runs from an `ensure` — frequently while another exception is
      # already unwinding. Raising here would replace the script's
      # real error with an incidental cleanup failure, so every close
      # is individually rescued and the errors are collected and
      # returned rather than thrown.
      #
      # The return value is deliberately not ignored-by-design: the
      # embedder may want to log cleanup failures, and a spec needs to
      # assert they happened. It is simply never allowed to alter
      # control flow.
      def close_all : Array(Exception)
        # DRAINED FIRST, then closed. Each `close_source` calls
        # `release` on its way out, which mutates `@open` — doing that
        # while iterating `@open` would skip entries. Taking the list
        # and clearing it up front makes those `release` calls
        # harmless no-ops against an already-empty array, and means an
        # iterator needs no special "am I being torn down?" case.
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
end
