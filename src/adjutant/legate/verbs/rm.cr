require "file_utils"
require "../broker"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # The `delete` grant's three verbs — LEGATE.md §4.4:
      #
      #   Legate.rm(path)      -> Bool      # a file
      #   Legate.rmdir(path)   -> Bool      # an EMPTY directory
      #   Legate.rmdir!(path)  -> Integer   # a whole tree, entries removed
      #
      # ## Why three names and not one verb with a flag
      #
      # This REVERSES §4.4's explicit "`rm` subsumes `rmdir` and
      # `unlink`," which was a deliberate simplification, and §4.4 has
      # been rewritten rather than left in disagreement with this
      # file. Recording the reasoning here as well, since the spec now
      # states only the outcome:
      #
      # Recursion only ever means directory-tree walking. It was
      # therefore always mis-attached to a verb that ALSO deletes
      # single files — `rm("f.txt", recursive: true)` is a sentence
      # with no meaning. That was tolerable while `recursive:` was the
      # only modifier in Legate. It stopped being tolerable once
      # `write!`/`cp!`/`mv!` established the bang as "do the more
      # destructive thing you would otherwise refuse", because `rm!`
      # would then have had to mean "recursive" — a second, unrelated
      # sense of the same suffix, in the same module, three verbs
      # apart. The bang convention did not exist when §4.4's line was
      # written, and it is what makes the extra name earn its place.
      #
      # `cp` keeps its `recursive:` kwarg and this is not an
      # inconsistency: there, `recursive:` governs the SOURCE (may I
      # walk a tree) while the bang governs the DESTINATION (may I
      # destroy what is there). Two orthogonal questions, two
      # spellings. Here there is no destination at all, so the two
      # questions collapse into one axis and a single spelling — the
      # name — carries it.
      #
      # ## What each verb refuses, and why the refusals cross-name
      #
      # Every refusal below is `Legate::Conflict` and every message
      # names the verb that WOULD have worked (principle 6). The three
      # verbs partition the target space exactly, so a script that
      # picked the wrong one is always one word from correct:
      #
      #   - `rm` on a directory     -> "use Legate.rmdir / Legate.rmdir!"
      #   - `rmdir` on a file       -> "use Legate.rm"
      #   - `rmdir` on a non-empty  -> "use Legate.rmdir!"
      #   - `rmdir!` on a file      -> "use Legate.rm"
      #
      # ## Conventions carried over unchanged from the single verb
      #
      #   - **A missing path is not an error, for any of the three.**
      #     `rm`/`rmdir` return `false`, `rmdir!` returns `0`. This is
      #     §2.3's "nil/0 for a non-existent path" family and the same
      #     spirit `mkdir` is idempotent in: "make sure this isn't
      #     here" has already succeeded if it was never here. It is
      #     deliberately a DIFFERENT convention from `cp`/`mv`'s
      #     `NotFound`-on-missing-source, which have been asked to do
      #     something impossible rather than something already done.
      #
      #     This is the reason `Broker#authorize_delete` has an
      #     `allow_missing` parameter (see its own comment):
      #     authorization still happens FIRST and in full, so a
      #     missing path OUTSIDE every granted delete root is still a
      #     fatal denial — "you may not delete here" is true
      #     regardless of whether anything happens to be there. Only
      #     once the grant says yes does absence become an ordinary
      #     result.
      #
      #   - **Symlinks are never followed.** Every existence and type
      #     test uses `File.info?(..., follow_symlinks: false)`, so
      #     these verbs remove THE LINK, never the thing it points at.
      #
      #     CORRECTED 2026-09-04, and the correction matters because
      #     the previous version of this comment claimed a hole the
      #     perimeter already closes. It said following would let a
      #     symlink planted inside a granted delete root delete an
      #     arbitrary target outside every root, "with the broker
      #     having authorized only the link's own in-bounds path."
      #     That is not what happens. `authorize_delete` passes
      #     `allow_missing: true`, so `check_root_maybe_missing`
      #     realpaths the deepest EXISTING ancestor — and a symlink is
      #     an existing entry, so it resolves to its out-of-root
      #     target and is DENIED before any of these verbs runs. Same
      #     finding as `write.cr`'s own destination check, reached the
      #     same way: by reading `grants.cr` rather than inferring
      #     from this file's prior comment.
      #
      #     What non-following actually buys, in decreasing order of
      #     importance:
      #       - `count_entries` does not DESCEND into a symlinked
      #         directory inside a tree. This is the real security
      #         property, and it is `rmdir!`-specific: the perimeter
      #         authorizes the tree's root, not every entry the walk
      #         reaches, so a link inside the tree is the one place a
      #         following walk could still escape.
      #       - `rm`/`rmdir` answer about the ENTRY the script named,
      #         so an in-root link to an in-root file removes the
      #         link and leaves the file, which is what "remove this
      #         path" means.
      #       - A dangling link is removable rather than reported as
      #         absent.
      #
      #   - **No byte budget is recorded.** `Budget` models bytes read
      #     and written; deletion moves neither, and there is no
      #     `record_delete`. The wall-clock check inside
      #     `authorize_delete` is the only budget mechanism a large
      #     `rmdir!` interacts with. A real, accepted gap: a script can
      #     delete an unbounded number of entries without touching its
      #     read/write budgets.
      #
      #   - **`reversible`/`severity` are set explicitly on all three**
      #     rather than left at their defaults. `Reversibility::Yes` on
      #     a verb whose entire purpose is destroying data would be
      #     wrong in the one direction a risk profile must never be
      #     wrong in.
      module Rm
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")

          register_rm(interp, legate, broker, conflict)
          register_rmdir(interp, legate, broker, conflict)
          register_rmdir_bang(interp, legate, broker, conflict)
        end

        # `Legate.rm(path) -> Bool` — files only.
        #
        # Returns `true` if a file was removed, `false` if nothing was
        # there. Bool rather than the count §4.4 used to specify: a
        # files-only verb can only ever return 0 or 1, and
        # `if Legate.rm(p) > 0` is a clumsy spelling of a yes/no. The
        # count survives on `rmdir!`, which is the verb where "how
        # many" is worth knowing.
        private def self.register_rm(interp : Interpreter, legate : RubyClass, broker : Broker,
                                     conflict : RubyClass) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("rm").value,
            RiskProfile.new(
              effects: Set{Effect::DeletesFiles},
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
          ) do |args, _blk, ncc|
            raw, label = target(args, ncc, broker)

            info = File.info?(raw, follow_symlinks: false)
            next Value.bool(false, label) unless info

            if info.directory?
              ncc.raise_error_class(
                "#{raw} is a directory; Legate.rm only removes files — use Legate.rmdir for an empty one or Legate.rmdir! for a tree",
                conflict,
              )
            end

            File.delete(raw)
            Value.bool(true, label)
          end
        end

        # `Legate.rmdir(path) -> Bool` — an EMPTY directory only.
        #
        # The non-recursive half of the old verb's directory case,
        # with the same emptiness rule §4.4 always required, now
        # carried by the name instead of the absence of a flag.
        private def self.register_rmdir(interp : Interpreter, legate : RubyClass, broker : Broker,
                                        conflict : RubyClass) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("rmdir").value,
            RiskProfile.new(
              effects: Set{Effect::DeletesFiles},
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
          ) do |args, _blk, ncc|
            raw, label = target(args, ncc, broker)

            info = File.info?(raw, follow_symlinks: false)
            next Value.bool(false, label) unless info

            refuse_file(raw, info, "rmdir", ncc, conflict)

            unless Dir.children(raw).empty?
              ncc.raise_error_class(
                "#{raw} is not empty; Legate.rmdir only removes an empty directory — use Legate.rmdir! to remove the tree",
                conflict,
              )
            end

            Dir.delete(raw)
            Value.bool(true, label)
          end
        end

        # `Legate.rmdir!(path) -> Integer` — the whole tree.
        #
        # Carries `Effect::Recursive`, which until this split was
        # declared and used by nothing: with `rm(path, recursive:
        # true)` the walker would have had to read a kwarg's LITERAL
        # value to know whether a given call recursed, which is why
        # the effect was parked. A verb that recurses unconditionally
        # needs no such inference — the name is the fact, and the
        # static manifest can report it.
        private def self.register_rmdir_bang(interp : Interpreter, legate : RubyClass, broker : Broker,
                                             conflict : RubyClass) : Nil
          legate.define_native_singleton_method(
            interp.symbols.intern("rmdir!").value,
            RiskProfile.new(
              effects: Set{Effect::DeletesFiles, Effect::Recursive},
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
          ) do |args, _blk, ncc|
            raw, label = target(args, ncc, broker)

            info = File.info?(raw, follow_symlinks: false)
            next Value.int(0_i64, label) unless info

            refuse_file(raw, info, "rmdir!", ncc, conflict)

            # Counted BEFORE the removal, not during — `FileUtils.rm_rf`
            # reports nothing about what it removed, and counting after
            # the fact is impossible by construction. Counting first and
            # then removing means the returned number is what the tree
            # HELD, which for a successful removal is exactly what was
            # removed; one that fails partway raises rather than
            # returning, so no caller ever sees a count that overstates
            # what happened.
            total = count_entries(raw)
            FileUtils.rm_rf(raw)
            Value.int(total, label)
          end
        end

        # Argument handling and authorization, identical for all
        # three verbs and therefore written once.
        #
        # Convention 3: join the resolved label rather than discarding
        # `authorize_delete`'s return value. Worth spelling out why a
        # Bool or an Integer gets a label at all, since these verbs
        # hand back no content: the result is derived from the target,
        # and it is a real (if narrow) channel — "does this file exist
        # inside a sensitive directory", or "how many entries does it
        # hold", is exactly the sort of thing a High-sensitivity path
        # should not answer into an unlabelled value that then flows
        # freely onward.
        private def self.target(args : Array(Value), ncc : NativeCallContext,
                                broker : Broker) : {String, RiskFlowLabel?}
          path_val = args[1]? || Value.nil_value
          str_val = ncc.call_method(path_val, "to_s", [] of Value)
          raw = str_val.as_string
          label = RiskFlowLabel.join(str_val.label, broker.authorize_delete(raw, ncc, allow_missing: true))
          {raw, label}
        end

        # Both directory verbs refuse a file target the same way, and
        # point at the same replacement.
        private def self.refuse_file(raw : String, info : File::Info, name : String,
                                     ncc : NativeCallContext, conflict : RubyClass) : Nil
          return if info.directory?

          ncc.raise_error_class(
            "#{raw} is a file, not a directory; Legate.#{name} only removes directories — use Legate.rm",
            conflict,
          )
        end

        # Deliberately a hand-written recursive walk rather than
        # `Dir.glob("#{dir}/**/*")`, for two reasons that both bite:
        # glob does NOT match dotfiles by default (a `.gitignore`
        # inside the tree would go uncounted, silently understating
        # the return value), and glob patterns need `/`-normalizing on
        # Windows to work at all (the bug class this codebase has hit
        # repeatedly — see `cp.cr`'s `directory_size` comment).
        # `Dir.children` has neither problem: it lists dotfiles, and
        # it takes a plain directory path rather than a pattern, so
        # there is no glob metacharacter or separator semantics
        # involved anywhere.
        #
        # Counts the directory ITSELF, plus every descendant — `rm -rf
        # dir` on a directory containing one file removes two entries,
        # and §4.4's "entries removed" is the honest reading of that.
        # Symlinks count as one entry each and are NOT descended into,
        # matching the non-following stance the whole module takes.
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
