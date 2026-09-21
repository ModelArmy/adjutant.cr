module Adjutant
  # A fatal condition raised by whatever is enforcing a run's limits —
  # a denied grant, an exhausted budget, a script-initiated abort.
  #
  # Deliberately a plain Crystal `Exception`, NOT `RuntimeError` — the
  # same shape as `VM::BlockBreakSignal` (vm.cr) and for the same
  # reason: the dispatch loop's per-instruction catch is typed `rescue
  # ex : RuntimeError` specifically (vm.cr, the `execute` loop), and
  # `call_native`'s own catch-all `rescue ex` (which would otherwise
  # flatten an arbitrary Crystal exception into a script-catchable N001
  # diagnostic) is bypassed the same way `BlockBreakSignal` bypasses
  # it — via an explicit, earlier `rescue ex : FatalSignal` clause in
  # `call_native` that re-raises unchanged rather than wrapping.
  # Neither catch point ever asks "does this match `Exception`" for a
  # `FatalSignal` — the whole rescue-matching machinery (HandlerEntry,
  # Op::PushError, RubyObject construction) is skipped entirely, not
  # merely failed. This is what makes `rescue Exception => e` genuinely
  # unable to catch it, not just discouraged from trying — a static
  # gate banning that syntax is a first line of defense, but the
  # runtime guarantee does not depend on the gate being correct or
  # even present.
  #
  # CONTRACT FOR ANYTHING THAT ENFORCES ITS OWN LIMITS: a fatal signal
  # only unwinds correctly if it IS a FatalSignal (or a subclass).
  # `call_native` rescues this type by name; an unrelated exception
  # class, however fatal its author intended it to be, gets flattened
  # into a script-catchable N001 by the catch-all below it.
  #
  # Core rather than Legate as of 2026-09-01. `VM#call_native` used to
  # rescue `Legate::FatalSignal` by name, which meant core reaching
  # down into Legate for a type — the layering inversion the
  # authorization promotion exists to remove. `Legate::FatalSignal`
  # remains as an alias so `rescue Legate::FatalSignal` sites and
  # LEGATE.md §9.2's naming stay accurate.
  #
  # `kind` is one of `:denied`, `:exhausted`, `:aborted` — used by the
  # single choke-point handler in `call_native` to know which error
  # class name to report under, and by specs to assert on cause
  # without string-matching `message`.
  class FatalSignal < Exception
    getter kind : Symbol
    getter data : Hash(String, String)

    def initialize(@kind : Symbol, message : String, @data = Hash(String, String).new)
      super(message)
    end
  end
end
