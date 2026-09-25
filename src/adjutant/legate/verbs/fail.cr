require "../broker"
require "../helpers"
require "../../fatal_signal"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.fail(message) -> no return` (LEGATE.md §4.7): the
      # script's own abort. Raises `FatalSignal.new(:aborted, message)`,
      # the fatal tier a denial uses (§9.2's "Legate::Aborted"), which
      # no `rescue` catches. `message` is required, since an abort
      # without a reason defeats its purpose, and is passed through
      # unchanged.
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
