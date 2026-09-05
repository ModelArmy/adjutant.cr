require "file_utils"
require "../broker"
require "../path"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.mv(from, to) -> Legate::Path` — LEGATE.md §4.4.
      #
      # DELIBERATE DIVERGENCE from a literal reading of §4.4, confirmed
      # with the embedder before implementing — the same shape of call
      # `cp.cr` documents, reached by the same reasoning from the
      # opposite direction. §4.4 places `mv` under grant `delete` and
      # its **Raises** line names only `NotFound`/`Conflict`, so a
      # literal reading gates this verb on `delete` alone. But `mv`
      # does not merely destroy the source: it CREATES CONTENT AT THE
      # DESTINATION, which is precisely what the `write` grant exists
      # to gate. Under the literal reading, a script holding `delete`
      # on some directory but no `write` grant anywhere could relocate
      # any file it can name to any path it can name, placing content
      # outside every write root — the mirror image of the hole
      # `cp.cr` closed by requiring `read` on its source.
      #
      # §4.4's own argument points the same way. It says a script
      # holding `write` but not `delete` can achieve a move only as
      # `cp` + `rm`, "which it cannot do — and that is the correct
      # outcome, since the two grants exist precisely to be
      # separable." Separability cuts both ways: a script holding
      # `delete` but not `write` should equally be unable to achieve a
      # move, for the same reason and by the same logic. So this verb
      # calls BOTH `authorize_delete` (on `from`) and `authorize_write`
      # (on `to`). Costs nothing for a script already holding both;
      # only changes behaviour for the delete-without-write case,
      # which is exactly the case worth closing. "You can't move a
      # file somewhere you can't write."
      #
      # `Conflict`, which §4.4 names without saying when, is raised
      # here for the two cases where the destination is occupied by
      # something a rename cannot legitimately replace:
      #   - `to` exists and is a DIRECTORY while `from` is a file (or
      #     vice versa) — replacing a directory with a file, or a file
      #     with a whole tree, is never what a caller meant.
      #   - `to` is a non-empty directory and `from` is a directory —
      #     the rename would either fail at the OS level or silently
      #     destroy unrelated content.
      # ## Two verbs, not one: replacement is opt-in
      #
      # `mv` REFUSES an occupied destination; `mv!` replaces it. The
      # comment this replaces said a plain file-over-file `mv`
      # overwrites "matching what `write` and `cp` already do" — which
      # was true, and was the problem. All three now refuse, and all
      # three offer a bang, so the consistency argument is preserved
      # and merely points the other way.
      #
      # `check_destination` was already halfway here: it refused to
      # replace a file with a directory or a directory with a file,
      # and refused a non-empty directory. Only the same-kind file
      # case renamed over the top. So this is a small extension of an
      # existing refusal rather than new machinery — those three
      # refusals survive on `mv!`, which lifts exactly one of them.
      #
      # ## The declaration CHANGES, and not only because of the split
      #
      # `mv` was `Reversibility::No` / `Severity::Warning` with
      # effects `DeletesFiles` + `WritesFiles`. It is now `Yes` /
      # `Info` with `MovesFiles` alone, and that would have been the
      # right declaration even before the bang existed. A move
      # preserves the information: `relocate` is `File.rename` on one
      # filesystem, and the `EXDEV` fallback is deliberately ordered
      # copy-then-delete so a partway failure duplicates rather than
      # loses. Nothing is destroyed in either path; the entry ends up
      # somewhere else.
      #
      # The old declaration came from §4.4's "a move both destroys and
      # creates," which is an argument about the GRANTS a move needs,
      # not about what survives it. Both authorizations below stay
      # exactly as they were — the asymmetry between what this verb
      # may do and what it consequently does is deliberate. See
      # `Effect::MovesFiles`' own comment.
      #
      # `mv!` is `No`/`Warning` with `MovesFiles` + `DeletesFiles`,
      # the latter about the clobbered destination, which is the same
      # thing `cp!` does and declared the same way.
      #
      # Note `mv!` replaces FILES ONLY. Unlike `cp!` it will not
      # replace a destination directory of any kind — see
      # `check_destination` for why, and for the platform difference
      # that forced the rule to be stated that plainly.
      module Mv
        # Matches `cp.cr`'s own `COPY_CHUNK_SIZE`, for the same
        # reason and used on the same code path shape — see the
        # cross-device fallback below.
        COPY_CHUNK_SIZE = 65_536

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          conflict = Helpers.fetch(legate, interp, "Conflict")
          path_cls = Helpers.fetch(legate, interp, "Path")

          register(interp, legate, broker, not_found, conflict, path_cls, clobber: false)
          register(interp, legate, broker, not_found, conflict, path_cls, clobber: true)
        end

        # One body, registered twice — `clobber` selects the name, the
        # risk profile and the destination rule, and nothing else.
        # Same shape as `write.cr` and `cp.cr`, deliberately: the
        # cross-device fallback below is the last thing that should
        # drift between two verbs that share it.
        private def self.register(interp : Interpreter, legate : RubyClass, broker : Broker,
                                  not_found : RubyClass, conflict : RubyClass, path_cls : RubyClass,
                                  clobber : Bool) : Nil
          name = clobber ? "mv!" : "mv"

          profile = if clobber
                      RiskProfile.new(
                        effects: Set{Effect::MovesFiles, Effect::DeletesFiles},
                        reversible: Reversibility::No,
                        severity: Severity::Warning,
                      )
                    else
                      # `MovesFiles` alone, and the defaults
                      # (`Yes`/`Info`) stated by omission the way every
                      # non-destructive verb states them. See the
                      # module comment for why this is a change of
                      # declaration and not merely a change of verb.
                      RiskProfile.new(effects: Set{Effect::MovesFiles})
                    end

          legate.define_native_singleton_method(
            interp.symbols.intern(name).value,
            profile,
          ) do |args, _blk, ncc|
            from_val = args[1]? || Value.nil_value
            from_str_val = ncc.call_method(from_val, "to_s", [] of Value)
            raw_from = from_str_val.as_string

            to_val = args[2]? || Value.nil_value
            to_str_val = ncc.call_method(to_val, "to_s", [] of Value)
            raw_to = to_str_val.as_string
            label = RiskFlowLabel.join(from_str_val.label, to_str_val.label)

            # `allow_missing: true` then an explicit check below —
            # same shape as `cp.cr`'s source handling and landing on
            # the same answer: a missing SOURCE is the recoverable
            # `Legate::NotFound` §4.4's own Raises line names, not a
            # fatal denial. (Contrast `rm.cr`, which passes the same
            # flag and deliberately reaches a DIFFERENT conclusion —
            # `0` — because §4.4 says so for that verb specifically.)
            label = RiskFlowLabel.join(label, broker.authorize_delete(raw_from, ncc, allow_missing: true))
            # `to` not existing yet is the normal case for a move,
            # same reasoning as `write.cr`/`cp.cr`.
            label = RiskFlowLabel.join(label, broker.authorize_write(raw_to, ncc, allow_missing: true))

            # `follow_symlinks: false` — `mv` relocates the ENTRY, not
            # the content behind it, so moving a symlink moves the
            # link itself, and (as in `rm.cr`) a symlink inside a
            # granted root must never become a lever for touching the
            # thing it points at.
            from_info = File.info?(raw_from, follow_symlinks: false)
            unless from_info
              ncc.raise_error_class("#{raw_from} not found", not_found)
            end

            check_destination(raw_from, raw_to, from_info.directory?, ncc, conflict, name, clobber)

            # "Parent directories are created automatically" is
            # §4.3's phrasing for the write grant, not §4.4's for this
            # one — but `mv`'s destination is a write in every sense
            # that matters (it's why this verb takes `authorize_write`
            # at all), and a script author moving a file into a fresh
            # output directory would be surprised to have to `mkdir`
            # first when `cp` into the same path needs no such thing.
            # Extended by analogy, deliberately.
            FileUtils.mkdir_p(File.dirname(raw_to))

            relocate(raw_from, raw_to, broker)

            Legate::Path.from_string(interp, path_cls, ::Path.new(raw_to).to_posix.to_s, label)
          end
        end

        # The destination rule. `follow_symlinks: false` was already
        # here and stays — for `mv` it is load-bearing in the same way
        # `rm.cr` describes, since this verb relocates the ENTRY, not
        # the content behind it.
        #
        # The plain verb refuses ANY occupied destination and stops
        # there. `mv!` keeps the three refusals that were always here
        # and lifts exactly one of them: same-kind file over file.
        private def self.check_destination(raw_from : String, raw_to : String, from_is_dir : Bool,
                                           ncc : NativeCallContext, conflict : RubyClass,
                                           name : String, clobber : Bool) : Nil
          to_info = File.info?(raw_to, follow_symlinks: false)
          return unless to_info

          to_is_dir = to_info.directory?

          unless clobber
            kind = to_is_dir ? "a directory" : "a file"
            ncc.raise_error_class(
              "#{raw_to} already exists and is #{kind}; Legate.#{name} won't replace it — use Legate.mv! to overwrite",
              conflict,
            )
          end

          # Replacing like with unlike is never what a caller meant,
          # so the bang does not offer it.
          if to_is_dir != from_is_dir
            kind = to_is_dir ? "a directory" : "a file"
            ncc.raise_error_class("#{raw_to} exists and is #{kind}; Legate.#{name} can't replace it with #{raw_from}", conflict)
          end

          # NO destination directory is replaced, empty or not. `cp!`
          # will replace a tree; `mv!` deliberately will not.
          #
          # This was originally "non-empty directories only", on the
          # reasoning that `relocate`'s rename would either fail at the
          # OS level or destroy the contents depending on which
          # filesystem the paths shared — and a verb whose effect turns
          # on that is worse than one that refuses. Correct as far as
          # it went, but it left the EMPTY case turning on the platform
          # instead: POSIX `rename(2)` happily replaces an empty
          # destination directory, while Windows `MoveFile` refuses
          # with "Access is denied". Found on Windows CI, 2026-09-05,
          # by a spec asserting the POSIX behaviour.
          #
          # So the rule now covers directories outright, and the
          # principle is the one the original comment was reaching for:
          # a verb should not behave differently depending on where it
          # happens to be running. `mv!` lifts EXACTLY ONE refusal —
          # same-kind file over file — and no others.
          #
          # A script that genuinely wants to replace a directory can
          # say so in two steps it already has: `Legate.rmdir` (or
          # `rmdir!`) then `Legate.mv`. Two verbs, both declared, both
          # audited — which is a better record of intent than one verb
          # quietly doing both.
          if to_is_dir
            ncc.raise_error_class(
              "#{raw_to} is a directory; Legate.#{name} won't replace one — remove it first with Legate.rmdir, then move",
              conflict,
            )
          end
        end

        # The move itself. `File.rename` is the whole verb whenever
        # source and destination share a filesystem: atomic, moves no
        # bytes, and leaves no window in which the entry exists at
        # neither path or both.
        #
        # NOT independently verified against a live toolchain: the
        # `EXDEV` detection below is written from recollection of
        # Crystal's `File::Error` exposing the underlying errno as
        # `os_error`, and of `File.rename` raising rather than
        # returning a status on failure. Same caveat this codebase
        # already flags on other stdlib-API assumptions — worth a
        # careful look during review, since a wrong guess here turns a
        # legitimate cross-device move into a raw, ugly error instead
        # of the fallback.
        private def self.relocate(raw_from : String, raw_to : String, broker : Broker) : Nil
          File.rename(raw_from, raw_to)
        rescue ex : File::Error
          raise ex unless ex.os_error == Errno::EXDEV
          # Cross-device move. There is no atomic primitive for this
          # at any level — the kernel refuses precisely because the
          # operation is copy-then-delete underneath — so the fallback
          # is that, explicitly, with the honest consequences:
          #
          #   - It is NOT atomic. A failure partway leaves the source
          #     intact and a partial destination behind. Deliberately
          #     ordered source-preserving: the delete happens only
          #     after the copy has fully succeeded, so the failure
          #     mode is "duplicated" rather than "lost." For a verb
          #     that destroys data, that is the only acceptable
          #     direction to fail in.
          #   - It DOES consume read and write budget, per chunk, the
          #     way `cp.cr` does — because it genuinely moves bytes.
          #     The rename path above consumes neither. That asymmetry
          #     is real and unavoidable: the same script-level call
          #     costs a different amount of budget depending on where
          #     the two paths happen to live. Naming it here rather
          #     than leaving a future reader to discover it.
          copy_tree(raw_from, raw_to, broker)
          FileUtils.rm_rf(raw_from)
        end

        private def self.copy_tree(raw_from : String, raw_to : String, broker : Broker) : Nil
          info = File.info?(raw_from, follow_symlinks: false)
          return unless info

          if info.directory?
            Dir.mkdir_p(raw_to)
            Dir.children(raw_from).each do |child|
              copy_tree(File.join(raw_from, child), File.join(raw_to, child), broker)
            end
            return
          end

          # Byte-level, chunked, with BOTH budgets recorded per chunk
          # — identical to `cp.cr`'s own `copy_file` loop and for the
          # identical reason: a huge move can hit either budget
          # partway through rather than only once fully buffered. No
          # temp-file/rename dance here, unlike `cp`: the destination
          # is already known not to be an occupied path of a
          # conflicting kind (checked above), and the fallback as a
          # whole is non-atomic by construction anyway, so a
          # per-file atomicity guarantee would buy nothing it could
          # actually keep.
          File.open(raw_from, "rb") do |src|
            File.open(raw_to, "wb") do |dst|
              buf = ::Bytes.new(COPY_CHUNK_SIZE)
              loop do
                n = src.read(buf)
                break if n == 0
                broker.budget.record_read(n.to_i64)
                dst.write(buf[0, n])
                broker.budget.record_write(n.to_i64)
              end
              dst.flush
              dst.fsync
            end
          end
        end
      end
    end
  end
end
