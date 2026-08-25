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
      # — LEGATE.md §4.1. Glob matching itself is Crystal's own
      # `Dir.glob` (per this session's own guidance not to reinvent
      # it) — this module's real job is authorization around that
      # call, sorting for determinism, and building `Entry` objects.
      module List
        KWARG_NAMES   = Set{"limit"}
        DEFAULT_LIMIT = 100_000

        # Glob metacharacters `Dir.glob` recognises — used ONLY to
        # find the pattern's fixed (non-wildcard) leading directory
        # for authorization (see `fixed_prefix` below), never to
        # reimplement matching itself.
        WILDCARD_CHARS = {'*', '?', '[', '{'}

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          too_many = Helpers.fetch(legate, interp, "TooMany")
          entry_cls = Helpers.fetch(legate, interp, "Entry")
          path_cls = Helpers.fetch(legate, interp, "Path")

          legate.define_native_singleton_method(
            interp.symbols.intern("list").value,
            RiskProfile.new(tags: Set{RiskTag::ReadsFiles}),
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            pattern_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(pattern_val, "to_s", [] of Value)
            pattern = str_val.as_string
            label = str_val.label

            # ONE broker call per `Legate.list` INVOCATION, not one
            # per matched file — checked against the pattern's fixed,
            # non-wildcard leading directory (`fixed_prefix` below), so
            # a list matching thousands of entries produces exactly
            # one audit record and one RiskFlowPolicy consultation,
            # matching how `read`/`stat` each make exactly one broker
            # call. `allow_missing: true` since a glob whose fixed
            # prefix doesn't exist is just an empty result (§4.1's
            # "an empty match is an empty Array, not an error"), not a
            # denial — same §2.3-flavoured reasoning as `stat`'s own
            # `allow_missing`.
            broker.authorize_read(fixed_prefix(pattern), ncc, allow_missing: true)

            matches = Dir.glob(pattern).sort

            # Defense in depth, NOT the primary enforcement — the
            # fixed-prefix check above is what a script should expect
            # to explain a `Legate.list` denial. This re-checks each
            # individual match against `read_roots` using Grants'
            # plain `check_root` DIRECTLY (not `broker.authorize_read`
            # again — no second audit entry, no second RiskFlowPolicy
            # consultation per file; that would defeat the whole point
            # of the single call above). Anything that unexpectedly
            # fails containment despite passing the fixed-prefix check
            # (a case this design doesn't currently know how to
            # produce, given no-follow-symlinks glob traversal — see
            # `Dir.glob`'s own doc caveat below) is silently dropped
            # rather than raising mid-list.
            in_bounds = matches.select { |match| broker.grants.check_root(match, broker.grants.read_roots).allowed? }

            limit = limit_of(ncc)
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
          given = ncc.kwargs.try(&.["limit"]?)
          given ? given.as_int.to_i32 : DEFAULT_LIMIT
        end

        # The longest leading run of `pattern`'s `/`-separated
        # components containing no glob metacharacter — e.g.
        # `"src/**/*.rb"` → `"src"`, `"/work/input/*.txt"` →
        # `"/work/input"`, a pattern that's ENTIRELY wildcard (e.g.
        # `"*.txt"`) falls back to `"."`, matching `Dir.glob`'s own
        # implicit current-directory base. Fed only to the single
        # `broker.authorize_read` call above — `Dir.glob` itself still
        # receives the ORIGINAL, unmodified `pattern`.
        private def self.fixed_prefix(pattern : String) : String
          kept = [] of String
          pattern.split('/').each do |part|
            break if part.each_char.any? { |char| WILDCARD_CHARS.includes?(char) }
            kept << part
          end
          prefix = kept.join('/')
          prefix.empty? ? "." : prefix
        end

        # `File.info?` (not `File.info`) — a match `Dir.glob` returned
        # a moment ago could already be gone by the time this runs
        # (deleted, or a broken symlink slipping through); such an
        # entry is silently skipped via `compact_map` above rather
        # than raising, the same small, accepted TOCTOU-class race
        # §8.1's own note already normalizes for this codebase.
        #
        # NOT independently verified: whether `Dir.glob`'s `**`
        # traversal follows symlinked directories by default. If it
        # does, §4.1's "symlinks reported, not followed" is only
        # honored for the LEAF entry's own reported `type` (via
        # `follow_symlinks: false` below, same as `Legate.stat`), not
        # for whether traversal walks THROUGH an intermediate
        # symlinked directory to find more matches — worth confirming
        # once `ops test` can exercise this against a real symlinked
        # directory.
        private def self.build_entry(interp : Interpreter, entry_cls : RubyClass, path_cls : RubyClass,
                                     match : String, label : RiskFlowLabel?) : Value?
          info = File.info?(match, follow_symlinks: false)
          return nil unless info
          path_val = Legate::Path.from_string(interp, path_cls, match, label)
          Legate::Entry.build(interp, entry_cls, path_val, type_of(info), info.size, mtime_of(interp, info), label)
        end

        # Duplicated from stat.cr rather than shared — both small
        # enough that factoring out a "verb helpers" module isn't
        # worth it yet; revisit once a THIRD verb needs this same
        # File::Info → Legate type-symbol mapping.
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
