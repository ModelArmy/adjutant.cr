require "file_utils"
require "../broker"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.rm(path, recursive: false) -> Integer` (entries
      # removed) — LEGATE.md §4.4. "`rm` subsumes `rmdir` and
      # `unlink`; without `recursive:` it raises `Legate::Conflict` on
      # a non-empty directory. `rm` on a missing path returns `0`
      # (§2.3)."
      #
      # Three things this verb does deliberately, none of them stated
      # outright by §4.4, all following from its own text plus the
      # conventions the read/write grants already established:
      #
      #   - **A missing path is `0`, not `Legate::Denied`.** This is
      #     the reason `Broker#authorize_delete` grew an
      #     `allow_missing` parameter (see its own comment): the
      #     strict `check_root` denies anything it can't resolve, and
      #     a denial is FATAL, so a literal wiring of this verb to the
      #     strict check would have made §4.4's documented `0` result
      #     unreachable for the exact case it exists to describe.
      #     Authorization still happens FIRST and in full — a missing
      #     path OUTSIDE every granted delete root is still a denial,
      #     because "you may not delete here" is true regardless of
      #     whether anything happens to be there right now. Only once
      #     the grant says yes does absence become `0`.
      #
      #   - **Symlinks are never followed.** Every existence and
      #     type test below uses `File.info?(..., follow_symlinks:
      #     false)`, so `rm` on a symlink removes THE LINK, never the
      #     thing it points at. This matters far more here than
      #     anywhere else in Legate: following would let a symlink
      #     planted inside a granted delete root delete an arbitrary
      #     target outside every root, with the broker having
      #     authorized only the link's own (perfectly in-bounds) path.
      #     Same non-following stance `stat.cr`/`list.cr` already take
      #     for their own reasons, but load-bearing for security here
      #     rather than merely descriptive.
      #
      #   - **No byte budget is recorded.** `Budget` (budget.cr) models
      #     bytes read and bytes written; deletion moves neither, and
      #     there is no `record_delete` to call. The wall-clock check
      #      inside `authorize_delete` is the only budget mechanism a
      #     large recursive `rm` interacts with. Worth naming as a
      #     real (accepted) gap rather than leaving as an apparent
      #     omission: a script can delete an unbounded number of
      #     entries without touching its read/write budgets, and only
      #     a wall-clock limit stops it.
      module Rm
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")

          legate.define_native_singleton_method(
            interp.symbols.intern("rm").value,
            # The first Legate verb to set `reversible`/`severity` at
            # all rather than tags alone — every verb so far has been
            # content with the defaults (`Yes`/`Info`), and for
            # reading, and even for writing (where the previous
            # content is at least reconstructible from whatever
            # produced it), that was defensible. Deletion is the point
            # at which the default becomes an outright false
            # statement: `Reversibility::Yes` on a verb whose entire
            # purpose is destroying data would be wrong in the one
            # direction a risk profile must never be wrong in.
            RiskProfile.new(
              effects: Set{Effect::DeletesFiles},
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
            Set{"recursive"},
          ) do |args, _blk, ncc|
            # Kwarg validation BEFORE `authorize_*` — convention 1:
            # a wrong-typed `recursive:` is a call-site programmer
            # error, unrelated to the grant, and shouldn't burn an
            # audit-log entry on a call that fails regardless.
            given = Helpers.checked_bool_kwarg(ncc, "Legate.rm", "recursive")
            recursive = given.nil? ? false : given

            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string

            # Convention 3: join the resolved label rather than
            # discarding `authorize_*`'s return value. Worth spelling
            # out why an INTEGER gets a label at all, since this verb
            # hands back no content: the count is derived from the
            # target, and a count is a real (if narrow) channel — "how
            # many entries does this sensitive directory hold" is
            # exactly the sort of thing a High-sensitivity path
            # shouldn't answer into an unlabelled Integer that then
            # flows freely onward. Labelling costs nothing here and
            # keeps this verb consistent with every other one rather
            # than making it the lone exception a future reader has to
            # explain.
            label = RiskFlowLabel.join(str_val.label, broker.authorize_delete(raw, ncc, allow_missing: true))

            info = File.info?(raw, follow_symlinks: false)
            # §4.4/§2.3's documented missing-path result. Note this is
            # a DIFFERENT convention from `cp`'s (and `mv`'s below)
            # `NotFound`-on-missing-source, deliberately so, and
            # LEGATE.md is explicit about which verb gets which: `rm`
            # is idempotent in the same spirit `mkdir` is — "make sure
            # this isn't here" has already succeeded if it was never
            # here — whereas a `cp`/`mv` with no source has simply
            # been asked to do something impossible.
            next Value.int(0_i64, label) unless info

            if info.directory?
              next Value.int(remove_directory(raw, recursive, ncc, conflict), label)
            end

            File.delete(raw)
            Value.int(1_i64, label)
          end
        end

        # The directory case. Without `recursive:`, §4.4 allows
        # removing an EMPTY directory (`rm` "subsumes `rmdir`", and
        # `rmdir` is precisely the empty-directory operation) and
        # requires `Legate::Conflict` on a non-empty one — so
        # emptiness, not directory-ness, is what the flag actually
        # gates. That's a meaningful difference from `cp`'s own
        # `recursive:`, which refuses a directory source outright
        # regardless of whether it's empty; the asymmetry is real and
        # comes straight from each section's own wording.
        private def self.remove_directory(raw : String, recursive : Bool,
                                          ncc : NativeCallContext, conflict : RubyClass) : Int64
          children = Dir.children(raw)

          unless recursive
            unless children.empty?
              ncc.raise_error_class("#{raw} is not empty; Legate.rm needs recursive: true to remove it", conflict)
            end
            Dir.delete(raw)
            return 1_i64
          end

          # Counted BEFORE the removal, not during — `FileUtils.rm_rf`
          # reports nothing about what it removed, and counting after
          # the fact is impossible by construction. Counting first and
          # then removing means the returned number is what the tree
          # HELD, which for a successful `rm` is exactly what was
          # removed; a `rm` that fails partway raises rather than
          # returning, so no caller ever sees a count that overstates
          # what happened.
          total = count_entries(raw)
          FileUtils.rm_rf(raw)
          total
        end

        # Deliberately a hand-written recursive walk rather than
        # `Dir.glob("#{dir}/**/*")`, for two reasons that both bite:
        # glob does NOT match dotfiles by default (a `.gitignore`
        # inside the tree would go uncounted, silently understating
        # the return value of a verb whose ONLY return value is that
        # count), and glob patterns need `/`-normalizing on Windows to
        # work at all (the bug class this codebase has hit repeatedly
        # — see `cp.cr`'s `directory_size` comment). `Dir.children`
        # has neither problem: it lists dotfiles, and it takes a plain
        # directory path rather than a pattern, so there is no glob
        # metacharacter or separator semantics involved anywhere.
        #
        # Counts the directory ITSELF, plus every descendant — `rm -rf
        # dir` on a directory containing one file removes two entries,
        # and §4.4's "entries removed" is the honest reading of that.
        # Symlinks count as one entry each and are NOT descended into,
        # matching the non-following stance the whole verb takes.
        private def self.count_entries(dir : String) : Int64
          total = 1_i64
          Dir.children(dir).each do |child|
            path = File.join(dir, child)
            info = File.info?(path, follow_symlinks: false)
            next unless info
            if info.directory?
              total += count_entries(path)
            else
              total += 1_i64
            end
          end
          total
        end
      end
    end
  end
end
