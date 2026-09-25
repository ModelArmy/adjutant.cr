require "../broker"
require "../../native_call_context"
require "../../builtins/time"

module Adjutant
  module Legate
    module Verbs
      # `Legate.now -> Time` (LEGATE.md §4.7): the builtin Time class,
      # as core's ungated `Time.now` returns. §4.7 calls the value
      # frozen, but Adjutant has no freezing, so `utc` and friends can
      # still change it in place.
      #
      # Time is looked up when called, not at bootstrap, since Legate
      # is bootstrapped before Time is registered. No effect and no
      # label: the clock isn't a source policy tracks.
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
