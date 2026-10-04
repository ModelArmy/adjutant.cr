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
          not_found = Helpers.fetch(legate, interp, "NotFoundError")
          too_large = Helpers.fetch(legate, interp, "TooLargeError")
          malformed = Helpers.fetch(legate, interp, "MalformedError")

          Helpers.define_verb(
            legate, interp, "read",
            RiskProfile.new(effects: Set{Effect::ReadsFiles}),
            KWARG_NAMES,
            # A Read sink, so `authorize_read` checks labelled arguments
            # at the path, then labels the path itself.
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
            # `Legate::NotFoundError` (or the `missing:` value), not a
            # denial. The path's label is joined with the one policy
            # gives it.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))

            # Follows symlinks, since `read` returns the target's
            # content; `Legate.stat` doesn't. A reported size over the
            # limit fails before opening; the read itself is bounded
            # too, since the reported size may be stale or 0.
            info = File.info?(raw, follow_symlinks: true)
            next missing_result(ncc, not_found, raw) unless info

            if info.size > limit
              ncc.raise_error_class(too_large_message(info.size, limit), too_large)
            end

            content = read_content(raw, limit, scrub, malformed, too_large, ncc, broker)
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

        # The file as a String, read with `Helpers.read_bounded`, so
        # one that grew past `limit` since it was checked raises
        # `too_large` without being read whole. Invalid UTF-8 is
        # scrubbed to U+FFFD, or raises `malformed` with `scrub: false`.
        private def self.read_content(path : String, limit : Int64, scrub : Bool, malformed : RubyClass,
                                      too_large : RubyClass, ncc : NativeCallContext, broker : Broker) : String
          raw_bytes = Helpers.read_bounded(path, limit, broker.budget)
          ncc.raise_error_class(too_large_message(nil, limit), too_large) unless raw_bytes
          raw_str = String.new(raw_bytes)
          return raw_str if raw_str.valid_encoding?

          if scrub
            raw_str.scrub
          else
            ncc.raise_error_class("#{path}: invalid UTF-8 byte sequence (scrub: false)", malformed)
          end
        end

        # §9.1's TooLargeError wording, in binary units. `size` is nil
        # for a file found over the limit only while reading it.
        private def self.too_large_message(size : Int64?, limit : Int64) : String
          what = size ? "path is #{Helpers.humanize_bytes(size)}, over" : "path is over"
          "#{what} the #{Helpers.humanize_bytes(limit)} read limit — use Legate.lines(path) or Legate.bytes(path) to stream."
        end
      end
    end
  end
end
