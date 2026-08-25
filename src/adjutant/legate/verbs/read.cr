require "../broker"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.read(path, limit:, scrub:, missing:) -> String` —
      # LEGATE.md §4.1.
      module Read
        # No declared defaults here (see NativeCallable#kwarg_names's
        # own comment) — each kwarg's default behavior is hand-rolled
        # below via presence checks on `ncc.kwargs`, the same
        # mrb_get_args-style convention that comment documents.
        KWARG_NAMES = Set{"limit", "scrub", "missing"}

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          too_large = Helpers.fetch(legate, interp, "TooLarge")
          malformed = Helpers.fetch(legate, interp, "Malformed")

          legate.define_native_singleton_method(
            interp.symbols.intern("read").value,
            RiskProfile.new(tags: Set{RiskTag::ReadsFiles}), # complements declare_sensitivity — see stat.cr's own comment on why both are needed
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # `allow_missing: true` — same reasoning as Legate.stat
            # (authorization.cr's check_root_maybe_missing): a missing
            # path under a granted root is `Legate::NotFound`
            # (recoverable, suppressible via `missing:`), NOT a
            # `Legate::Denied` fatal. Only a path OUTSIDE every
            # granted root is a real denial, regardless of whether it
            # happens to exist.
            broker.authorize_read(raw, ncc, allow_missing: true)

            # §8.1 step 3's "open by the resolved path" — following
            # symlinks here (unlike Legate.stat, which deliberately
            # does NOT — see that verb's own comment on why the two
            # differ): `read` returns file CONTENT, so it follows the
            # link to whatever real file the content should come
            # from, same as `File.read` always has.
            info = File.info?(raw, follow_symlinks: true)
            next missing_result(ncc, not_found, raw) unless info

            limit = effective_limit(ncc, broker)
            if info.size > limit
              ncc.raise_error_class(too_large_message(size: info.size, limit: limit), too_large)
            end

            content = read_content(raw, scrub_flag(ncc), malformed, ncc)
            broker.budget.record_read(info.size)
            Value.string(content, label)
          end
        end

        # `limit:` may only make the effective cap STRICTER than
        # policy, never looser — a script passing a bigger `limit:`
        # than `grants.limits.read_limit` does not get to read more
        # than the embedder configured; this is a judgment call
        # LEGATE.md §4.1 doesn't spell out explicitly (it only shows
        # `limit: policy.read_limit` as the shown DEFAULT value), but
        # letting a script escalate its own read cap past what policy
        # set would make `limit:` a privilege-escalation knob rather
        # than the "advice, switch to streaming" mechanism §7's own
        # text describes it as.
        private def self.effective_limit(ncc : NativeCallContext, broker : Broker) : Int64
          policy_limit = broker.grants.limits.read_limit
          given = ncc.kwargs.try(&.["limit"]?)
          return policy_limit unless given
          requested = given.as_int
          requested < policy_limit ? requested : policy_limit
        end

        # Presence, not value, is what matters — `ncc.kwargs.try(&.[
        # "missing"]?)` returns Crystal `nil` when the kwarg was
        # OMITTED (default §4.1 behavior: raise) and a real `Value`
        # (even one wrapping Ruby `nil`) when it was GIVEN, however
        # given — `missing: nil` and `missing: "{}"` both count as
        # "given," matching §2.5's own two examples exactly. This is
        # the same distinction `declare_sensitivity`'s doc comment
        # elsewhere in this codebase calls out for Hash lookups in
        # general: Crystal nil means "key absent," never confused
        # with a present, Ruby-nil-valued Value.
        private def self.missing_result(ncc : NativeCallContext, not_found : RubyClass, raw : String) : Value
          given = ncc.kwargs.try(&.["missing"]?)
          return given if given
          ncc.raise_error_class("#{raw} not found", not_found)
        end

        private def self.scrub_flag(ncc : NativeCallContext) : Bool
          given = ncc.kwargs.try(&.["scrub"]?)
          given ? given.as_bool : true
        end

        # NOT independently verified against a live toolchain: this
        # relies on Crystal's `String.new(Bytes)` substituting invalid
        # UTF-8 byte sequences with U+FFFD rather than raising —
        # matching §2.6's own default (`scrub: true`) behavior for
        # free if true, but load-bearing for `scrub: false` too, which
        # is detected here by comparing the SCRUBBED string's own
        # bytes back against the original raw bytes: if they differ,
        # something was substituted, so `scrub: false` raises
        # `Legate::Malformed`. Chosen over calling a dedicated
        # validation API directly because it only depends on
        # `String.new(Bytes)`'s substitution behavior and basic
        # `Bytes` equality, both more standard/stable than guessing at
        # a scrub-specific method name this codebase has never called
        # before — if `ops test` shows `String.new(Bytes)` actually
        # raises on invalid input instead of substituting, this whole
        # method needs revisiting, not just a signature tweak.
        private def self.read_content(path : String, scrub : Bool, malformed : RubyClass, ncc : NativeCallContext) : String
          raw_bytes = File.open(path, "rb") do |file|
            slice = Bytes.new(file.size)
            file.read_fully(slice)
            slice
          end
          scrubbed = String.new(raw_bytes)
          if !scrub && scrubbed.to_slice != raw_bytes
            ncc.raise_error_class("#{path}: invalid UTF-8 byte sequence (scrub: false)", malformed)
          end
          scrubbed
        end

        # §9.1's own worked example for TooLarge's required wording —
        # matched as closely as sensible, with one deliberate wording
        # deviation: the spec's own example mixes decimal ("1.4 GB")
        # and binary ("8 MiB") units in the SAME sentence, which reads
        # as an inconsistency in the spec text itself rather than a
        # meaningful distinction; this always uses binary units
        # (KiB/MiB/GiB) for BOTH numbers, matching `SizeLiteral`
        # (grants.cr) and the rest of this codebase's own vocabulary.
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
