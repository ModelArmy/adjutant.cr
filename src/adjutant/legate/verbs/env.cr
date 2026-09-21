require "../broker"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.env(name) -> String | nil` — LEGATE.md §4.7.
      #
      # The only ambient verb that goes through `Broker#authorize`:
      # the `ambient.env` allowlist is a real grant, and env allowlists
      # commonly gate secrets, so every lookup gets an `AuditRecord`
      # like any read/write/delete/net call. A name outside the
      # allowlist raises `Legate::Denied` (fatal, unrescuable).
      #
      # Steps:
      # 1. Validate `name` (R043 when missing, R039 when not a String).
      # 2. Authorize against the allowlist; this also resolves the
      #    name's sensitivity and applies `RiskFlowPolicy` to it.
      # 3. Return nil if the variable is unset, otherwise its value
      #    carrying the label from step 2.
      module Env
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("env").value,
            RiskProfile.none,
          ) do |args, _blk, ncc|
            name_val = args[1]?
            if name_val.nil?
              ncc.raise_error("R043", {} of String => String, "ArgumentError")
            end
            unless name_val.string?
              Helpers.raise_arg_type_error(ncc, "Legate.env", "name", "String", name_val)
            end
            name = name_val.as_string

            label = broker.authorize_env(name, ncc)

            raw = ENV[name]?
            next Value.nil_value unless raw

            Value.string(raw, label)
          end
        end
      end
    end
  end
end
