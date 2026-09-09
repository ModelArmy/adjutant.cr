require "../broker"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.random(n = nil) -> Float | Integer` — LEGATE.md §4.7.
      # No `n` (or an explicit `nil`) gives a Float in [0.0, 1.0), the
      # same shape as real Ruby's bare `Kernel#rand`. `n` a positive
      # Integer gives an Integer in [0, n); `n` a positive Float gives
      # a Float in [0, n) — both matching real Ruby's `rand(n)`
      # overloads.
      #
      # `n <= 0` raises (R042) rather than following real Ruby's own
      # "treat non-positive as though absent" quirk (`rand(0) ==
      # rand()`, `rand(-3)` silently uses `3`) — a value that LOOKS
      # like a deliberate argument silently producing a DIFFERENT
      # shape of result is exactly the kind of surprise this
      # codebase's own error-catalog conventions (ERRORS.md) favor a
      # clean, explicit rejection over.
      #
      # Crystal's plain `::Random.rand`, NOT `Random::Secure` — this
      # is `Kernel#rand`'s job, not a cryptographic one; real Ruby's
      # own `rand` isn't cryptographically secure either, and nothing
      # about "ambient random data for a script" implies it needs to
      # be.
      #
      # No effect declared and no RiskFlowLabel: freshly generated
      # data, derived from nothing an embedder would need provenance
      # tracked for.
      #
      # This module's name shadows Crystal's own top-level `::Random`
      # for every OTHER file in this namespace too, not just this one
      # — confirmed against a live `crystal build`, 2026-09-09, when
      # `cp.cr` and `write.cr`'s own unqualified `Random::Secure.
      # hex(8)` calls broke the moment this module existed (Crystal's
      # constant lookup found this Secure-less module before
      # continuing outward to the stdlib one). Kept named `Random`
      # anyway, matching every other verb module's exact-match-the-
      # verb-string convention — `cp.cr`/`write.cr` were qualified to
      # `::Random::Secure` instead, and any FUTURE file in this
      # namespace wanting the real `Random`/`Random::Secure` needs the
      # same `::` prefix. `git grep 'Random::Secure' src/adjutant/
      # legate/verbs` finds every site that needs it if this is ever
      # forgotten.
      module Random
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("random").value,
            RiskProfile.none,
          ) do |args, _blk, ncc|
            n_val = args[1]?
            next Value.float(::Random.rand) if n_val.nil? || n_val.null?

            if n_val.int?
              n = n_val.as_int
              ncc.raise_error("R042", {"method" => "Legate.random"}, "ArgumentError") if n <= 0
              next Value.int(::Random.rand(n))
            end

            if n_val.float?
              n = n_val.as_float
              ncc.raise_error("R042", {"method" => "Legate.random"}, "ArgumentError") if n <= 0.0
              next Value.float(::Random.rand(n))
            end

            Helpers.raise_arg_type_error(ncc, "Legate.random", "n", "Integer, Float, or nil", n_val)
          end
        end
      end
    end
  end
end
