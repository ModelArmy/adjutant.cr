require "log"
require "../broker"
require "../helpers"
require "../../value"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.log(message, fields = {}) -> nil` — LEGATE.md §4.7.
      #
      # SPEC NOTE: §4.7 as originally written specified this as
      # `Legate.log(message, **fields)` — a true variadic keyword
      # spray. Built instead as a single positional `fields` Hash,
      # 2026-09-08, because Adjutant's native-call dispatch has no
      # wildcard kwarg mechanism: every native method declares a
      # FIXED `kwarg_names : Set(String)` up front
      # (`NativeCallable#kwarg_names`), and `VM#check_unknown_native_
      # keywords!` rejects any name outside it — an empty declared
      # set (the default) rejects every kwarg name outright, and
      # there is no "accept anything" sentinel. Extending core VM
      # dispatch to support unbounded kwarg names, for the sake of
      # one convenience verb, is a bigger and riskier change than this
      # verb warrants — see SCOPE.md for the fuller writeup and the
      # option of doing that properly later if a real second need for
      # it turns up. `Legate.log("done", {status: "ok", count: 3})`
      # carries exactly the same information as the spec'd
      # `Legate.log("done", status: "ok", count: 3)` would have; only
      # the punctuation at the call site differs.
      #
      # Writes through `broker.log` — an embedder-supplied `::Log`
      # (`Legate::Broker#log`'s own comment has the full reasoning for
      # why this lives on the broker rather than being hardcoded to
      # one library-wide source). `fields`' values are converted via
      # `Value#to_plain` (`value.cr`) into the restricted shape
      # `Log::Metadata`/`Log::Emitter#emit` actually accept — see that
      # method's own comment for what does and doesn't survive the
      # conversion (a Sym becomes its name; a Proc/RubyObject/RubyClass
      # raises rather than silently stringifying).
      #
      # `Effect::ExternalOutput` (risk_profile.cr): the static risk
      # sweep's honest answer to "what does this call do" — data can
      # leave the sandbox through it, via a destination the script
      # itself never names or sees.
      #
      # `authorities: Set{Authority::Log}` (below) is the half that
      # actually DOES something, not just reports: it makes
      # `Legate.log` a real SINK in `VM#check_risk_flow`'s
      # labeled-argument check — the same generic mechanism
      # `risk_flow_enforcement_spec.cr` proves correct, just never
      # before connected to an actual Legate verb. A script that logs
      # a value carrying a RiskFlowLabel (from `Legate.read`,
      # `Legate.fetch`, `Legate.env`, ...) now has that check consult
      # `RiskFlowPolicy#action_for(Authority::Log, sensitivity)` the
      # SAME way a tainted argument reaching any other risky call
      # would, and can be Asked about or flatly Rejected — this is
      # the actual fix for reading a sensitive file and logging it as
      # exfiltration, not the Effect above, which only makes the
      # possibility visible in a report someone has to go read.
      # `authorities:` is NOT the same thing as going through
      # `Broker#authorize` (ambient verbs still bypass that whole
      # sequence — no wall-clock check, no AuditRecord for this) —
      # it's a separate, narrower mechanism that only ever looks at
      # already-labeled arguments. Added 2026-09-10; full reasoning,
      # including why NO other Legate verb has this same protection
      # yet, in SCOPE.md.
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

            # `Log::Metadata`'s TOP-LEVEL entries require `Symbol`
            # keys (confirmed against a live `crystal build`,
            # 2026-09-08 — `Log::Metadata#setup`, `log/metadata.cr`,
            # builds a `NamedTuple(key: Symbol, value: ...)` per
            # entry). That is not a type-annotation nuance to work
            # around: Crystal's own docs are explicit that "Symbols
            # are interpreted at compile time and cannot be created
            # dynamically" — there is no runtime String-to-Symbol
            # conversion at all, by design (unlike Ruby's `#to_sym`).
            # Since `fields`' KEYS are chosen by the SCRIPT at
            # runtime, they can never be real Symbols, so they can
            # never be Metadata's own top-level entry names.
            #
            # The fix is to not need them to be: nest `fields` one
            # level down, under the single Symbol key `:fields` —
            # which IS known at compile time, because it's a literal
            # right here in this file, not script data. `Log::
            # Metadata::Value::Type` (Crystal stdlib) explicitly
            # allows `Hash(String, Log::Metadata::Value)` as a VALUE
            # (nested, not top-level), which is exactly what `fields`
            # already is. An embedder reading `entry.data` sees
            # `{fields: {"status" => "ok", ...}}` — one level of
            # unwrapping, and the only shape Crystal's own Symbol
            # model actually permits for runtime-named data.
            broker.log.info do |emitter|
              emitter.emit(message, {fields: fields})
            end

            Value.nil_value
          end
        end

        # `args[2]?` absent entirely (the caller wrote no second
        # argument at all) is the ordinary "no fields" case and
        # defaults to empty — there is no VM-level default-filling
        # for a native call's trailing positional argument the way a
        # compiled script method gets one, so this verb supplies its
        # own, the same way every Legate verb with an optional
        # argument already does for its own kwargs.
        private def self.fields_of(fields_val : Value?, ncc : NativeCallContext) : Hash(String, PlainValue)
          return {} of String => PlainValue if fields_val.nil?

          hash = fields_val.as_hash?
          unless hash
            Helpers.raise_arg_type_error(ncc, "Legate.log", "fields", "Hash", fields_val)
          end

          out = {} of String => PlainValue
          hash.each do |key, value|
            # Either key spelling is accepted — `{status: "ok"}`
            # (Symbol, Ruby's shorthand, and what every example in
            # this file's own top comment uses) or `{"status" =>
            # "ok"}` (String) — converted to a String either way for
            # OUR OWN output Hash. String, deliberately, not Symbol:
            # `key` is script-chosen at RUNTIME, and Crystal Symbols
            # can only ever be created from a compile-time literal —
            # there is no runtime String-to-Symbol conversion at all.
            # `emitter.emit` below nests this whole Hash under a
            # single Symbol key it controls (`:fields`, a literal in
            # THIS file) rather than trying to use script-chosen names
            # as Metadata's own top-level entries — see that call
            # site's own comment for why that split is required, not
            # a style choice.
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
