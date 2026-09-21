require "../broker"
require "../../native_call_context"
require "../../builtins/time"

module Adjutant
  module Legate
    module Verbs
      # `Legate.now -> Time` — LEGATE.md §4.7.
      #
      # Reuses the SAME `Time` class (`builtins/time.cr`) an
      # unrestricted, already-existing `Time.now` singleton method
      # already returns — not a separate `Legate::Time` type. §4.7
      # itself says `-> Time`, not `-> Legate::Time`, and there is
      # nothing about wall-clock time that needs its own value type
      # once one already exists; this verb exists for §4.7's own
      # completeness, not because `Time.now` itself was ever gated.
      #
      # "frozen" (§4.7's own annotation) is ASPIRATIONAL, same as
      # every other Legate value type described that way —
      # `Legate::Response`'s own comment (`legate/response.cr`) says
      # so explicitly for its own "frozen" claim. Adjutant has no
      # real `freeze`/`frozen?` mechanism at all yet (vm.cr's own
      # `dup`/`clone` comment says the same). A script CAN call
      # `#utc`/`#gmtime`/`#localtime` on the value this returns and
      # mutate it in place, exactly as it could on a bare `Time.now`
      # — building real immutability enforcement is a VM-wide
      # feature, not something this one verb should invent
      # unilaterally.
      #
      # `Time`'s own RubyClass is looked up via `interp.get_global(
      # "Time")` INSIDE the native block (call time), not captured at
      # `.bootstrap` time: `Legate::Verbs::Now.bootstrap` runs from
      # inside `Interpreter#bootstrap_legate`, which itself runs
      # BEFORE `Time` is registered — `bootstrap_builtin_classes`
      # (interpreter.cr) calls `bootstrap_error_classes` (which reaches
      # `bootstrap_legate`) before it reaches its own
      # `register_builtin_class(Builtins.bootstrap_time(self))` call.
      # Deferring the lookup to call time, long after every builtin is
      # registered, sidesteps that ordering entirely rather than
      # reordering a bootstrap sequence this file doesn't own.
      #
      # No effect declared (`RiskProfile.none`) and no RiskFlowLabel:
      # wall-clock time isn't derived from anything an embedder would
      # want provenance tracked for — the same reasoning
      # `Legate.scratch`'s own freshly-generated path carries no
      # label.
      module Now
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("now").value,
            RiskProfile.none,
          ) do |_args, _blk, _ncc|
            time_cls = interp.get_global("Time").as_rclass
            Value.robject(TimeObject.new(time_cls, ::Time.local))
          end
        end
      end
    end
  end
end
