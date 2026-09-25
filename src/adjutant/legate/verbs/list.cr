require "../broker"
require "../entry"
require "../path"
require "../exceptions"
require "../helpers"
require "../../builtins/time"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.list(pattern, limit: 100_000) -> Array<Legate::Entry>`
      # (LEGATE.md §4.1): `Dir.glob`, authorized, sorted, as Entries.
      module List
        KWARG_NAMES   = Set{"limit"}
        DEFAULT_LIMIT = 100_000

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          too_many = Helpers.fetch(legate, interp, "TooMany")
          entry_cls = Helpers.fetch(legate, interp, "Entry")
          path_cls = Helpers.fetch(legate, interp, "Path")

          # A Read sink; see read.cr.
          legate.define_native_singleton_method(
            interp.symbols.intern("list").value,
            RiskProfile.new(effects: Set{Effect::ReadsFiles}),
            KWARG_NAMES,
            authorities: Set{Authority::Read},
          ) do |args, _blk, ncc|
            # `limit:` is validated before authorizing.
            limit = limit_of(ncc)

            pattern_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(pattern_val, "to_s", [] of Value)
            pattern = str_val.as_string
            label = str_val.label

            # One authorization per call, against the pattern's fixed
            # leading directory, so a large listing makes one audit
            # record. A missing prefix is an empty result, not a denial.
            # The pattern is converted to `/` separators first, which
            # `Dir.glob` requires on every platform.
            posix_pattern = ::Path.new(pattern).to_posix.to_s
            # The prefix's sensitivity labels the whole listing; no
            # entry is looked up on its own.
            label = RiskFlowLabel.join(label, broker.authorize_read(Helpers.fixed_prefix(posix_pattern), ncc, allow_missing: true))

            matches = Dir.glob(posix_pattern).sort

            # Each match is also checked for containment, without an
            # audit record; one that fails is dropped.
            in_bounds = matches.select { |match| broker.grants.check_root(match, broker.grants.read_roots).allowed? }

            if in_bounds.size > limit
              ncc.raise_error_class(
                "#{pattern} matched #{in_bounds.size} entries, over the #{limit} limit — narrow the pattern or raise limit:.",
                too_many,
              )
            end

            entries = in_bounds.compact_map { |match| build_entry(interp, entry_cls, path_cls, match, label) }
            Value.new(LabeledArray.new(entries, label), label)
          end
        end

        private def self.limit_of(ncc : NativeCallContext) : Int32
          given = Helpers.checked_int_kwarg(ncc, "Legate.list", "limit")
          given ? given.to_i32 : DEFAULT_LIMIT
        end

        # Nil for a match that has disappeared since the glob, which is
        # skipped. The entry's type doesn't follow a final symlink.
        # Whether `**` traverses symlinked directories is Crystal's
        # `Dir.glob` behaviour, unconfirmed here.
        private def self.build_entry(interp : Interpreter, entry_cls : RubyClass, path_cls : RubyClass,
                                     match : String, label : RiskFlowLabel?) : Value?
          info = File.info?(match, follow_symlinks: false)
          return unless info
          # `Dir.glob` returns `\` separators on Windows, and
          # Legate::Path splits on `/` only, so the match is converted
          # first.
          path_val = Legate::Path.from_string(interp, path_cls, ::Path.new(match).to_posix.to_s, label)
          Legate::Entry.build(interp, entry_cls, path_val, type_of(info), info.size, mtime_of(interp, info), label)
        end

        # The same mapping as stat.cr's.
        private def self.type_of(info : File::Info) : Symbol
          case info.type
          when File::Type::File      then :file
          when File::Type::Directory then :dir
          when File::Type::Symlink   then :symlink
          else                            :other
          end
        end

        private def self.mtime_of(interp : Interpreter, info : File::Info) : Value
          time_cls = interp.get_global("Time").as_rclass
          Value.robject(TimeObject.new(time_cls, info.modification_time))
        end
      end
    end
  end
end
