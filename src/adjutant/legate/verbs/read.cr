require "../broker"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.read(path, limit:, scrub:, missing:) -> String`
      # (LEGATE.md §4.1).
      module Read
        # Defaults are applied by the verb, not declared.
        KWARG_NAMES = Set{"limit", "scrub", "missing"}

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          too_large = Helpers.fetch(legate, interp, "TooLarge")
          malformed = Helpers.fetch(legate, interp, "Malformed")

          legate.define_native_singleton_method(
            interp.symbols.intern("read").value,
            RiskProfile.new(effects: Set{Effect::ReadsFiles}),
            KWARG_NAMES,
            # A Read sink, so `VM#check_risk_flow` checks labelled
            # arguments; `declare_sensitivity` labels the path itself.
            authorities: Set{Authority::Read},
          ) do |args, _blk, ncc|
            # Keywords are validated before authorizing, so a bad
            # keyword costs no audit record.
            limit = effective_limit(ncc, broker)
            scrub = scrub_flag(ncc)

            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # A missing path inside a granted root is
            # `Legate::NotFound` (or the `missing:` value), not a
            # denial. The path's label is joined with the one policy
            # gives it.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))

            # Follows symlinks, since `read` returns the target's
            # content; `Legate.stat` doesn't. The size is checked before
            # opening, and the file read at its size when opened.
            info = File.info?(raw, follow_symlinks: true)
            next missing_result(ncc, not_found, raw) unless info

            if info.size > limit
              ncc.raise_error_class(too_large_message(size: info.size, limit: limit), too_large)
            end

            content = read_content(raw, scrub, malformed, ncc)
            broker.budget.record_read(info.size)
            Value.string(content, label)
          end
        end

        # `limit:`, clamped to `read_limit`: it can tighten the policy's
        # cap, never loosen it.
        private def self.effective_limit(ncc : NativeCallContext, broker : Broker) : Int64
          policy_limit = broker.grants.limits.read_limit
          requested = Helpers.checked_int_kwarg(ncc, "Legate.read", "limit")
          return policy_limit unless requested
          requested < policy_limit ? requested : policy_limit
        end

        # `missing:`'s value, returned as given, if the keyword was
        # passed at all (`missing: nil` counts, §2.5); otherwise raises
        # `not_found`.
        private def self.missing_result(ncc : NativeCallContext, not_found : RubyClass, raw : String) : Value
          given = ncc.kwargs.try(&.["missing"]?)
          return given if given
          ncc.raise_error_class("#{raw} not found", not_found)
        end

        private def self.scrub_flag(ncc : NativeCallContext) : Bool
          given = Helpers.checked_bool_kwarg(ncc, "Legate.read", "scrub")
          given.nil? ? true : given
        end

        # Reads the whole file as a String. Invalid UTF-8 is scrubbed to
        # U+FFFD, or raises `malformed` with `scrub: false`.
        private def self.read_content(path : String, scrub : Bool, malformed : RubyClass, ncc : NativeCallContext) : String
          raw_bytes = File.open(path, "rb") do |file|
            slice = ::Bytes.new(file.size)
            file.read_fully(slice)
            slice
          end
          raw_str = String.new(raw_bytes)
          return raw_str if raw_str.valid_encoding?

          if scrub
            raw_str.scrub
          else
            ncc.raise_error_class("#{path}: invalid UTF-8 byte sequence (scrub: false)", malformed)
          end
        end

        # §9.1's TooLarge wording, in binary units for both sizes.
        private def self.too_large_message(size : Int64, limit : Int64) : String
          "path is #{humanize_bytes(size)}, over the #{humanize_bytes(limit)} read limit — use Legate.lines(path) or Legate.bytes(path) to stream."
        end

        private def self.humanize_bytes(n : Int64) : String
          if n >= 1024_i64 ** 3
            "#{(n / (1024.0 ** 3)).round(1)} GiB"
          elsif n >= 1024_i64 ** 2
            "#{(n / (1024.0 ** 2)).round(1)} MiB"
          elsif n >= 1024_i64
            "#{(n / 1024.0).round(1)} KiB"
          else
            "#{n} B"
          end
        end
      end
    end
  end
end
