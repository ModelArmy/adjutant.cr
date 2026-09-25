require "../broker"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.random(n = nil) -> Float | Integer` (LEGATE.md §4.7).
      # No `n` gives a Float in [0, 1); a positive Integer `n` an
      # Integer in [0, n); a positive Float `n` a Float in [0, n), as
      # Ruby's `rand` does. A non-positive `n` raises R042, where Ruby
      # silently treats `rand(0)` as `rand` and `rand(-3)` as `rand(3)`.
      #
      # Crystal's `::Random.rand`, not a cryptographic generator, as
      # Ruby's `rand` isn't. No effect and no label.
      #
      # This module's name hides Crystal's `Random` for every file in
      # this namespace, so they write `::Random::Secure`.
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
