require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # A fatal Legate condition (`Legate::Denied`, `Legate::Exhausted`,
    # `Legate::Aborted` — LEGATE.md §9.2). Deliberately a plain Crystal
    # `Exception`, NOT `RuntimeError` — the same shape as `VM::BlockBreakSignal`
    # (vm.cr) and for the same reason: the dispatch loop's per-instruction
    # catch is typed `rescue ex : RuntimeError` specifically (vm.cr, the
    # `execute` loop), and `call_native`'s own catch-all `rescue ex` (which
    # would otherwise flatten an arbitrary Crystal exception into a
    # script-catchable N001 diagnostic) is bypassed the same way
    # `BlockBreakSignal` bypasses it — via an explicit, earlier `rescue ex :
    # Legate::FatalSignal` clause in `call_native` that re-raises unchanged
    # rather than wrapping. Neither catch point ever asks "does this match
    # `Exception`" for a `FatalSignal` — the whole rescue-matching machinery
    # (HandlerEntry, Op::PushError, RubyObject construction) is skipped
    # entirely, not merely failed. This is what makes `rescue Exception => e`
    # genuinely unable to catch it, not just discouraged from trying — the
    # static gate (LEGATE.md §10.2) bans that syntax as the first line of
    # defense, but the runtime guarantee does not depend on the gate being
    # correct or even present.
    #
    # `kind` is one of `:denied`, `:exhausted`, `:aborted` — used by the
    # single choke-point handler in call_native to know which Legate error
    # class name to report under, and by specs to assert on cause without
    # string-matching `message`.
    class FatalSignal < Exception
      getter kind : Symbol
      getter data : Hash(String, String)

      def initialize(@kind : Symbol, message : String, @data = Hash(String, String).new)
        super(message)
      end
    end

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
        %w[NotFound Malformed TooLarge TooMany Timeout Transport Conflict NonZeroExit].each do |name|
          Helpers.nest(legate, interp, name, error)
        end
      end
    end
  end
end
