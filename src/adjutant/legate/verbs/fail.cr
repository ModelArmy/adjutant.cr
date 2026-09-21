require "../broker"
require "../helpers"
require "../../fatal_signal"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.fail(message) -> no return` — LEGATE.md §4.7. A
      # sanctioned abort: raises the fatal, unrescuable
      # `FatalSignal.new(:aborted, message)` (`fatal_signal.cr`) —
      # same tier and same unrescuability as a denied grant (`deny!`,
      # `broker.cr`), the difference being WHO decided to stop the
      # run. A denial is the perimeter refusing; `Legate.fail` is the
      # script itself choosing to stop, with its own reason, rather
      # than continue on data or a state it has judged unsafe to
      # proceed from. §9.2 documents this as "Legate::Aborted —
      # `Legate.fail`, or a runtime invariant broken," and like
      # `Legate::Denied`/`Legate::Exhausted` (`fatal_signal.cr`'s own
      # comment, `exceptions.cr`) that is a naming convention carried
      # by `FatalSignal#kind`, not a real RubyClass — nothing a
      # script could ever `rescue` by that name, on purpose.
      #
      # `message` is required, unlike almost every other Legate verb
      # argument, which has a documented default: an abort with no
      # explanation defeats the entire point of choosing to fail
      # deliberately rather than letting some other error surface on
      # its own. Passed through UNPREFIXED and unmodified as
      # `FatalSignal#message` — this is the one place in Legate where
      # the exact wording is entirely the script author's choice, not
      # a system-generated denial/conflict message, and rewriting it
      # would take that away for no benefit.
      module Fail
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("fail").value,
            RiskProfile.none,
          ) do |args, _blk, ncc|
            message_val = args[1]?
            if message_val.nil?
              ncc.raise_error("R040", {} of String => String, "ArgumentError")
            end
            unless message_val.string?
              Helpers.raise_arg_type_error(ncc, "Legate.fail", "message", "String", message_val)
            end

            raise FatalSignal.new(:aborted, message_val.as_string)
          end
        end
      end
    end
  end
end
