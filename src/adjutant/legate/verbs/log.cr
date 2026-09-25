require "log"
require "../broker"
require "../helpers"
require "../../value"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.log(message, fields = {}) -> nil` (LEGATE.md §4.7).
      # `fields` is a positional Hash rather than `**fields`, because a
      # native method declares a fixed set of keyword names and the VM
      # rejects any other.
      #
      # Writes to the host's `broker.log` at Info. Field values go
      # through `Value#to_plain`: a Symbol becomes its name, and a Proc,
      # class or object raises.
      #
      # There's no grant, so no `Broker#authorize`, no wall-clock check
      # and no audit record. It is a Log sink: a labelled argument is
      # checked against `RiskFlowPolicy#action_for(Authority::Log, ...)`
      # and can be asked about or rejected, which is what stops a
      # sensitive value being logged out. It declares
      # `Effect::ExternalOutput`, since the host picks a destination
      # the script can't see.
      module Log
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("log").value,
            RiskProfile.new(effects: Set{Effect::ExternalOutput}),
            authorities: Set{Authority::Log},
          ) do |args, _blk, ncc|
            message_val = args[1]?
            if message_val.nil?
              ncc.raise_error("R041", {} of String => String, "ArgumentError")
            end
            unless message_val.string?
              Helpers.raise_arg_type_error(ncc, "Legate.log", "message", "String", message_val)
            end
            message = message_val.as_string

            fields = fields_of(args[2]?, ncc)

            # Metadata's top-level keys must be Symbols, which Crystal
            # can't create at runtime, so the script's field names are
            # nested under one literal key: an entry's data reads
            # `{fields: {"status" => "ok", ...}}`.
            broker.log.info do |emitter|
              emitter.emit(message, {fields: fields})
            end

            Value.nil_value
          end
        end

        # The fields as a String-keyed Hash; empty when omitted.
        private def self.fields_of(fields_val : Value?, ncc : NativeCallContext) : Hash(String, PlainValue)
          return {} of String => PlainValue if fields_val.nil?

          hash = fields_val.as_hash?
          unless hash
            Helpers.raise_arg_type_error(ncc, "Legate.log", "fields", "Hash", fields_val)
          end

          out = {} of String => PlainValue
          hash.each do |key, value|
            # A Symbol or String key, kept as a String.
            key_name = if key.string?
                         key.as_string
                       elsif key.symbol?
                         key.as_sym.name
                       else
                         Helpers.raise_arg_type_error(ncc, "Legate.log", "fields", "Hash with String or Symbol keys", fields_val)
                       end
            begin
              out[key_name] = value.to_plain
            rescue ArgumentError
              Helpers.raise_arg_type_error(
                ncc, "Legate.log", "fields",
                "Hash of loggable values (String, Integer, Float, true/false, nil, Array, or Hash of the same)",
                value,
              )
            end
          end
          out
        end
      end
    end
  end
end
