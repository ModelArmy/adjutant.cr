require "../broker"
require "../helpers"
require "../../fatal_signal"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.env(name) -> String | nil` — LEGATE.md §4.7.
      #
      # Bypasses `broker.authorize_*` entirely, same as every other
      # ambient verb (`Ambient` is absent from `Broker::AUTHORITIES`
      # — `broker.cr`'s own comment) — but UNLIKE `scratch`/`log`/
      # `fail`, this one still has a real grant to consult:
      # `grants.ambient_env`, the `ambient.env` allowlist (§7). A name
      # outside it is denied the same way a normal grant denial is —
      # `FatalSignal.new(:denied, ...)`, fatal and unrescuable — just
      # constructed directly here rather than through
      # `Broker#authorize`'s own (private) `deny!`, since there is no
      # `Authority` to authorize against and no wall-clock/
      # RiskFlowPolicy sequence this needs.
      #
      # AUDIT ASYMMETRY, noted rather than resolved: unlike a normal
      # grant denial (which appends an `AuditRecord` before raising —
      # `Adjutant::Broker#authorize`), this denial does not, matching
      # every other ambient verb's own "skip the whole audit
      # mechanism" treatment for consistency. Unlike `scratch`/`fail`
      # though, THIS denial is a genuine policy-enforcement event an
      # embedder reviewing "what did this script try and fail to do"
      # might reasonably want visibility into, since env allowlists
      # commonly gate secrets. Flagged, not fixed — see SCOPE.md.
      #
      # `Authority::Ambient` (`authority.cr`) exists for exactly this
      # case: not a sink anything authorizes against, but a real
      # SOURCE a sensitivity declaration can name.
      # `ncc.declare_sensitivity` is the same mechanism
      # `Legate.read`/`Legate.fetch` use to label their own results —
      # called directly here, standalone, since it is fully
      # self-contained (`native_function_call.cr`/`vm.cr`) and does
      # not depend on `authorize`'s wrapping sequence to work
      # correctly. Skipped entirely when the name is simply unset
      # (`ENV[name]?` is nil) — there is no data to label.
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

            unless broker.grants.ambient_env.includes?(name)
              raise FatalSignal.new(:denied, "Legate.env denied: #{name.inspect} is not in the ambient.env allowlist")
            end

            raw = ENV[name]?
            next Value.nil_value unless raw

            label = ncc.declare_sensitivity(Authority::Ambient, ProvenanceKind::Env, name)
            Value.string(raw, label)
          end
        end
      end
    end
  end
end
