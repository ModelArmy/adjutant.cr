require "file_utils"
require "../broker"
require "../path"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.cp(from, to, recursive: false) -> Legate::Path` —
      # LEGATE.md §4.3.
      #
      # DELIBERATE DIVERGENCE from a literal reading of §4.3's own
      # structure, confirmed with the embedder before implementing:
      # `cp` is grouped under "grant `write`" alongside `write`/
      # `append`/`mkdir`, and its own **Raises** line only names
      # `NotFound`/`Conflict` — nothing about a `read` grant. But `cp`
      # fundamentally READS `from`'s content. Authorizing only the
      # WRITE side (as the doc's own grouping suggests read literally)
      # would let a script with a `write` grant somewhere — but NO
      # `read` grant anywhere — copy the contents of ANY file it can
      # NAME into its own writable area, completely bypassing what the
      # `read` grant exists to gate. So this verb calls BOTH
      # `authorize_read` (on `from`) and `authorize_write` (on `to`),
      # not just the latter. Costs nothing for the common case (a
      # script that already holds both grants); only changes behavior
      # for the write-only-no-read case, which is exactly the case
      # worth closing. "You can't copy a file you can't read."
      #
      # Two further judgment calls, both extending §4.3's text by
      # analogy rather than following it literally, since it doesn't
      # address either case for `cp` specifically:
      #   - Parent directories of `to` are created automatically,
      #     matching `write`/`append`/`mkdir`'s own stated behavior —
      #     `cp` sits in the exact same "grant `write`" section and a
      #     script author would reasonably expect the same convenience.
      #   - The FILE-copy case (not the directory case — see below) is
      #     made atomic the same way `write.cr` is (temp file, same
      #     directory, `fsync`, `rename`) — LEGATE.md's atomicity
      #     sentence names `write` specifically, but `cp` copying a
      #     file is, from the DESTINATION's point of view, exactly the
      #     same "replace this path's entire content" operation
      #     `write` performs; leaving it non-atomic would be a
      #     surprising regression for a verb whose entire point is
      #     "copy this file safely."
      #
      # ## Two verbs, not one: replacement is opt-in
      #
      # `cp` REFUSES an occupied destination; `cp!` replaces it. Both
      # are registered here from one shared body, the same shape
      # `write.cr` uses and for the same reason — the atomicity dance,
      # the budget accounting and the chunk loop must not drift apart
      # between them.
      #
      # This verb had TWO clobber sites, and the directory one was the
      # more dangerous. `copy_file` renamed over an existing file, and
      # `copy_directory` called `FileUtils.rm_rf(raw_to)` before its
      # rename — so a recursive copy onto an existing directory
      # DELETED THE WHOLE TREE and put its own in place. Not a merge,
      # which is what a `cp -r` habit expects, and not recoverable.
      # Both sites declared `Reversibility::Yes` / `Severity::Info`
      # while doing it, and the perimeter cannot catch either: a
      # destination inside a granted write root is exactly what the
      # grant permits.
      #
      # `recursive:` STAYS on both verbs, and the two flags are
      # orthogonal by design: `recursive:` is about the SOURCE (may I
      # walk a tree), the bang is about the DESTINATION (may I destroy
      # what is already there). `cp!(from, to, recursive: true)` says
      # both, and says them separately. That orthogonality is exactly
      # what `rm` lacks today — a single `recursive:` flag doing duty
      # for both questions — and is why `rm` splits by NAME rather
      # than growing a bang of its own.
      module Cp
        # 64 KiB — matches `bytes.cr`'s own `DEFAULT_CHUNK_SIZE`, for
        # the same reason: large enough to not be silly, small enough
        # that both the read AND write budgets get checked
        # PROGRESSIVELY through a big file copy, not only once at the
        # end.
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
        private def self.register(interp : Interpreter, legate : RubyClass, broker : Broker,
                                  not_found : RubyClass, conflict : RubyClass, path_cls : RubyClass,
                                  clobber : Bool) : Nil
          name = clobber ? "cp!" : "cp"

          profile = if clobber
                      # `DeletesFiles` is the honest declaration for
                      # both clobber paths: a replaced file's previous
                      # content is gone, and a replaced DIRECTORY is
                      # an `rm_rf` of a tree the script never named.
                      # Same reasoning `write!` and `mv!` carry it.
                      RiskProfile.new(
                        effects: Set{Effect::ReadsFiles, Effect::WritesFiles, Effect::DeletesFiles},
                        reversible: Reversibility::No,
                        severity: Severity::Warning,
                      )
                    else
                      RiskProfile.new(effects: Set{Effect::ReadsFiles, Effect::WritesFiles})
                    end

          legate.define_native_singleton_method(
            interp.symbols.intern(name).value,
            profile,
            Set{"recursive"},
          ) do |args, _blk, ncc|
            recursive = recursive_flag(ncc, name)

            from_val = args[1]? || Value.nil_value
            from_str_val = ncc.call_method(from_val, "to_s", [] of Value)
            raw_from = from_str_val.as_string

            to_val = args[2]? || Value.nil_value
            to_str_val = ncc.call_method(to_val, "to_s", [] of Value)
            raw_to = to_str_val.as_string
            label = RiskFlowLabel.join(from_str_val.label, to_str_val.label)

            # `allow_missing: true` then an explicit check below — same
            # §2.3-flavoured reasoning as every read-grant verb: a
            # missing SOURCE is `Legate::NotFound` (recoverable,
            # LEGATE.md's own documented raise for it), not a fatal
            # `Denied`; only a source outside every granted READ root
            # is a real denial.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw_from, ncc, allow_missing: true))
            # `to` not existing yet is the normal case, same reasoning
            # as `write.cr`.
            label = RiskFlowLabel.join(label, broker.authorize_write(raw_to, ncc, allow_missing: true))

            # `follow_symlinks: true` — `cp` copies CONTENT, same
            # reasoning `read.cr`'s own comment gives for following
            # symlinks (unlike `stat`/`list`, which deliberately don't).
            from_info = File.info?(raw_from, follow_symlinks: true)
            unless from_info
              ncc.raise_error_class("#{raw_from} not found", not_found)
            end

            if from_info.directory?
              copy_directory(raw_from, raw_to, recursive, broker, ncc, conflict, name, clobber)
            else
              copy_file(raw_from, raw_to, broker, ncc, conflict, name, clobber)
            end

            Legate::Path.from_string(interp, path_cls, ::Path.new(raw_to).to_posix.to_s, label)
          end
        end

        private def self.recursive_flag(ncc : NativeCallContext, name : String) : Bool
          given = Helpers.checked_bool_kwarg(ncc, "Legate.#{name}", "recursive")
          given.nil? ? false : given
        end

        # The destination rule for the non-clobbering verbs, shared by
        # both the file and directory paths so they cannot disagree.
        #
        # `follow_symlinks: false`, matching `write.cr`'s own
        # `check_destination` and for the same verified reason: a link
        # pointing OUT of every granted root is already denied by
        # `check_root_maybe_missing`, which realpaths the deepest
        # existing ancestor. What not-following buys here is the
        # DANGLING link, which resolves to a prospective in-root path
        # and so is allowed by the perimeter — following it would
        # report nothing at the destination and let the copy replace
        # the link with a regular file.
        #
        # Called AFTER the source checks (`NotFound`, and the
        # directory-without-`recursive:` refusal) deliberately. Both
        # of those are about whether the call makes sense at all; an
        # occupied destination is only interesting once it does, and a
        # script that got `recursive:` wrong should be told that
        # rather than being told about the destination.
        private def self.refuse_occupied_destination(raw_to : String, name : String,
                                                     ncc : NativeCallContext, conflict : RubyClass) : Nil
          info = File.info?(raw_to, follow_symlinks: false)
          return unless info

          kind = info.directory? ? "a directory" : "a file"
          ncc.raise_error_class(
            "#{raw_to} already exists and is #{kind}; Legate.#{name} won't replace it — use Legate.cp! to overwrite",
            conflict,
          )
        end

        # `recursive: false` (the default) against a directory SOURCE
        # is the one case this verb refuses outright — LEGATE.md gives
        # `cp` a `recursive:` kwarg at all specifically so a script
        # opts into a whole-tree copy deliberately, not by accident
        # (copying a huge directory tree because `from` happened to be
        # a directory would be a nasty surprise without this).
        private def self.copy_directory(raw_from : String, raw_to : String, recursive : Bool,
                                        broker : Broker, ncc : NativeCallContext, conflict : RubyClass,
                                        name : String, clobber : Bool) : Nil
          unless recursive
            ncc.raise_error_class("#{raw_from} is a directory; Legate.#{name} needs recursive: true to copy it", conflict)
          end

          unless clobber
            refuse_occupied_destination(raw_to, name, ncc, conflict)
          end

          if File.exists?(raw_to) && !File.directory?(raw_to)
            ncc.raise_error_class("#{raw_to} exists and is not a directory; Legate.#{name} can't copy a directory there", conflict)
          end

          dest_parent = File.dirname(raw_to)
          FileUtils.mkdir_p(dest_parent)
          temp_dir = File.join(dest_parent, ".legate-cp-#{Random::Secure.hex(8)}.tmp")
          begin
            # NOT independently verified against a live toolchain:
            # `FileUtils.cp_r` is written from recollection of
            # Crystal's own `file_utils` module mirroring Ruby's
            # `FileUtils.cp_r` fairly closely (recursive copy,
            # creating `temp_dir` as the destination root) — same
            # caveat this codebase already flags for other stdlib-API
            # assumptions.
            FileUtils.cp_r(raw_from, temp_dir)
            # Budget accounted for POST HOC here (sum the copied
            # tree's total size, one `record_write` call after the
            # fact) rather than progressively per file the way the
            # single-FILE case below manages — `cp_r` gives no
            # per-file progress callback to hook into. Real, accepted
            # limitation: a directory copy can't hit budget
            # exhaustion PARTWAY through the way every other
            # streaming operation in this codebase can; it only
            # notices after the whole tree is already copied (into
            # the TEMP directory — the real `raw_to` is still
            # untouched at that point, so at least the atomicity
            # guarantee below isn't compromised by this).
            broker.budget.record_write(directory_size(temp_dir))
            # Directory rename is ATOMIC on the same filesystem, same
            # guarantee `File.rename` gives the single-file case —
            # `temp_dir` living in `to`'s own parent directory is what
            # makes this hold, same reasoning as `write.cr`'s own temp
            # file placement.
            # REPLACES the destination tree; it does not merge into
            # it. Only reachable from `cp!` now — the plain verb
            # refused an occupied destination above — but the
            # distinction is worth stating outright even for the bang,
            # because a `cp -r` habit expects a merge and this is the
            # one place where an unexamined analogy to the shell tool
            # costs a whole directory. `DeletesFiles` on `cp!`'s
            # profile is this line.
            FileUtils.rm_rf(raw_to) if File.directory?(raw_to)
            File.rename(temp_dir, raw_to)
          rescue ex
            FileUtils.rm_rf(temp_dir) if File.exists?(temp_dir)
            raise ex
          end
        end

        # `::Path.new(path).to_posix` before building the glob
        # PATTERN — `path` here is `temp_dir`, itself built via
        # `File.join` (native separators on Windows), but `Dir.glob`
        # requires `/`-separated patterns on every platform (backslash
        # is its escape character, not a separator — the exact same
        # fact `list.cr`/`grep.cr`'s own pattern normalization already
        # accounts for). Without this, the glob below would silently
        # match nothing on Windows, undercounting (or zeroing) the
        # write-budget accounting this method exists for — caught by
        # re-auditing this file for the same bug class, not by a live
        # Windows run. Plain `Dir.glob(pattern)` (no block form) here,
        # matching every OTHER verb's own proven-working call shape
        # this session, rather than introducing an unverified block-
        # form Dir.glob call for this one method.
        private def self.directory_size(path : String) : Int64
          pattern = "#{::Path.new(path).to_posix}/**/*"
          total = 0_i64
          Dir.glob(pattern).each do |entry|
            info = File.info?(entry, follow_symlinks: false)
            total += info.size if info && info.file?
          end
          total
        end

        # The FILE-copy case — atomic (temp file, same directory as
        # `to`, `fsync`, `rename`), same shape as `write.cr`'s own
        # atomicity, and BYTE-level (no UTF-8 decoding/`scrub:`
        # anywhere — `cp` doesn't care whether the content is text at
        # all, unlike `read`/`lines`). Reads and writes in
        # `COPY_CHUNK_SIZE` pieces, recording BOTH the read budget
        # (source) and write budget (destination) PER CHUNK — a huge
        # file copy can hit EITHER budget partway through, not only
        # once fully buffered.
        private def self.copy_file(raw_from : String, raw_to : String, broker : Broker,
                                   ncc : NativeCallContext, conflict : RubyClass,
                                   name : String, clobber : Bool) : Nil
          unless clobber
            refuse_occupied_destination(raw_to, name, ncc, conflict)
          end

          if File.directory?(raw_to)
            ncc.raise_error_class("#{raw_to} is a directory; Legate.#{name} can't overwrite it with file content", conflict)
          end

          dest_dir = File.dirname(raw_to)
          FileUtils.mkdir_p(dest_dir)
          temp_path = File.join(dest_dir, ".legate-cp-#{Random::Secure.hex(8)}.tmp")

          begin
            File.open(raw_from, "rb") do |src|
              File.open(temp_path, "wb") do |dst|
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
            File.rename(temp_path, raw_to)
          rescue ex
            File.delete(temp_path) if File.exists?(temp_path)
            raise ex
          end
        end
      end
    end
  end
end
