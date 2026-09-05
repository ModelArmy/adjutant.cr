require "../fatal_signal"
require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `FatalSignal` moved to core on 2026-09-01: `VM#call_native`
    # rescues it by name, so core was reaching down into Legate for a
    # type. Aliased here so `rescue Legate::FatalSignal` sites,
    # LEGATE.md §9.2's naming and the verb comments referring to
    # `Legate::FatalSignal` all stay accurate. See
    # `src/adjutant/fatal_signal.cr` for the full reasoning on why it
    # is a plain Exception rather than a RuntimeError.
    alias FatalSignal = ::Adjutant::FatalSignal

    module Exceptions
      # Populates `legate`'s recoverable exception tier (`Legate::Error
      # < StandardError` and its eight subclasses per LEGATE.md §9.1).
      # Nests each into `legate` (built once, shared across every
      # Legate submodule — see Legate::Helpers.build_module/#nest) via
      # real `ConstPath`-resolvable nesting, not a flat "Legate::Error"
      # global name — see Legate::Helpers.nest's own comment for the
      # full mechanism. None of the eight error classes are registered
      # as top-level globals in their own right; only `legate` itself
      # is (Interpreter#bootstrap_error_classes).
      #
      # Takes `standard_error` as a parameter rather than looking it up
      # by name — `Interpreter#globals` has no public accessor (by
      # design; see `define_global_class`), and
      # `bootstrap_exception_and_subclasses` already has the real
      # RubyClass in hand mid-construction, so the call site
      # (Interpreter#bootstrap_error_classes) threads it through
      # directly instead of round-tripping through a symbol lookup.
      #
      # The fatal tier (Denied/Exhausted/Aborted) is deliberately NOT
      # built here, and has no RubyClass at all: it never becomes a
      # script-visible RubyObject in the first place (see FatalSignal,
      # above), so there is nothing for a `rescue` clause to match
      # against regardless of whether a class of that name exists.
      # `kind` on FatalSignal — not a RubyClass — is the only thing
      # that names which fatal condition occurred, and it is surfaced
      # solely through the run log / diagnostic channel (LEGATE.md
      # §8.6), never through anything a script's own rescue clauses
      # can see.
      def self.bootstrap(interp : Interpreter, legate : RubyClass, standard_error : RubyClass) : Nil
        error = Helpers.nest(legate, interp, "Error", standard_error)
        # `EOF` — the single-pass-stream tier, added when
        # `Legate::Stream` (stream.cr) gained real enforcement of "one
        # terminal walk per stream lineage" (LEGATE.md §6.1, amended
        # this session): calling a terminal a second time on an
        # already-walked stream (or anything derived from it via
        # `map`/`select`/`take`, which share consumption state with
        # their ancestor) raises this rather than silently returning
        # empty. Named for the well-known IO concept (Ruby's own
        # `EOFError` on a second `readline` past end-of-stream) rather
        # than anything Legate-specific, and deliberately generic
        # enough to cover a future network stream (`Legate.fetch
        # stream: true`, §3's own type-index diagram) the same way it
        # covers a file — not `Legate::StreamConsumed` or similar,
        # which would only make sense for files.
        %w[NotFound Malformed TooLarge TooMany Timeout Transport Conflict NonZeroExit EOF].each do |name|
          Helpers.nest(legate, interp, name, error)
        end

        bootstrap_redirect(interp, legate, error)
      end

      # `Legate::Redirect` — LEGATE.md §4.5. Raised when a request that
      # CARRIED A BODY is redirected, handing the decision back to the
      # script rather than following on its behalf.
      #
      # THE ONLY LEGATE ERROR THAT CARRIES DATA, and the reason
      # `raise_error_class` gained an `attributes` parameter at all
      # (see DEVELOPMENT.md's exception-handling section). Every other
      # error here says everything it has to say in its message; this
      # one expects a script to BRANCH on the status — auto-following a
      # 303 receipt while surfacing a 307 for a human — and recovering
      # a status code by string-matching a sentence written for a
      # human is not something a script should have to do.
      #
      # Two readers, both plain values a script hands straight back to
      # `Legate.fetch`: `status` is the Integer HTTP status, `location`
      # the target URL as a String. `location` is deliberately NOT
      # wrapped in a value type the way a filesystem path becomes a
      # `Legate::Path` — there is no URL type in Legate to wrap it in,
      # and inventing one for a single field would be a worse trade
      # than leaving it a String that the very next `Legate.fetch`
      # call parses and re-authorizes from scratch anyway.
      private def self.bootstrap_redirect(interp : Interpreter, legate : RubyClass,
                                          error : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Redirect", error)
        status_sym = interp.symbols.intern("status").value
        location_sym = interp.symbols.intern("location").value

        # `|| Value.nil_value` rather than an assertion: an error
        # object of this class could in principle be constructed by a
        # script's own `raise Legate::Redirect, "..."`, which attaches
        # no attributes at all. Returning nil there is the same
        # forgiving shape `#message` already has, and is far better
        # than a native method raising while a script is in the middle
        # of rescuing something.
        Builtins.define(cls, interp, "status") do |args|
          args.first.as_robject.ivars[status_sym]? || Value.nil_value
        end

        Builtins.define(cls, interp, "location") do |args|
          args.first.as_robject.ivars[location_sym]? || Value.nil_value
        end
      end
    end
  end
end
