require "file_utils"
require "../broker"
require "../stream"
require "../exceptions"
require "../helpers"
require "../../builtins/helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.write(path, data) -> Integer` (bytes written) —
      # LEGATE.md §4.3. First `write`-grant verb; the anchor for
      # `append`/`mkdir`/`cp` to follow, since they share most of this
      # file's own infrastructure (parent-dir creation, budget
      # tracking, the `data` shape).
      #
      # Two requirements from §4.3's own text drive this file's whole
      # shape:
      #
      #   1. "`write` MUST be atomic: temporary file in the same
      #      directory, `fsync`, then `rename`." — real POSIX
      #      same-filesystem `rename` is atomic; writing to a `.tmp`
      #      sibling first means a script (or a crash, or a budget
      #      exhaustion partway through a huge stream) can NEVER leave
      #      the real target path in a partially-written state — it's
      #      either the OLD complete content or the NEW complete
      #      content, never a mix. The temp file living in the SAME
      #      directory as the target isn't incidental — it's what
      #      guarantees `rename` stays on one filesystem (a cross-
      #      device rename isn't atomic, and on POSIX often isn't even
      #      possible at all).
      #   2. "`data` is a String or any Enumerable of Strings,
      #      including a Legate stream — so a pipeline never
      #      materialises merely to reach disk." — `Legate::Stream.
      #      walk` (made public this session, stream.cr's own comment
      #      on why) is what makes this real: a stream's elements are
      #      written ONE AT A TIME as they're pulled, never collected
      #      into an Array first. The actual dispatch on `data`'s shape
      #      lives in `Helpers.write_io_data`/`write_io_piece`
      #      (extracted there, not kept here, once `append.cr` needed
      #      the exact same logic byte for byte — see that file's own
      #      comment).
      #
      # ## Two verbs, not one: replacement is opt-in
      #
      # `write` REFUSES an existing destination; `write!` replaces it.
      # Both are registered here, from one shared body differing only
      # in that check, because everything else about them — atomicity,
      # budget, the `data` shape, parent creation — is identical and
      # must stay so.
      #
      # The original single verb renamed over an existing file with no
      # check at all, while declaring `Reversibility::Yes` /
      # `Severity::Info`. That combination is the failure this split
      # exists to fix: the perimeter cannot catch it. A destination
      # inside a granted write root is exactly what the grant permits,
      # so `Grants` answers yes and the previous content is gone, with
      # no layer below this one to notice. Making replacement the
      # DEFAULT meant every script that merely got a path wrong
      # destroyed a file silently.
      #
      # The bang is Ruby's own dangerous-variant convention and now
      # reads identically across `write!`, `cp!` and `mv!`: "do the
      # more destructive thing you would otherwise refuse." It is the
      # only spelling that stays consistent once `rm`/`rmdir`/`rmdir!`
      # exist, where a bang meaning "recursive" would have made the
      # suffix mean two different things in one module.
      #
      # Note what each may then declare. `write` cannot destroy, so
      # `Yes`/`Info` is now true rather than merely unchallenged;
      # `write!` takes `No`/`Warning`, which is the honest reading of
      # a verb that replaces content the caller never named.
      #
      # `Conflict` (recoverable, and already named in §4.3's own
      # **Raises** line) is the exception for BOTH the occupied-
      # destination refusal and the directory-target refusal. They are
      # the same category of answer — "something is already at this
      # path and I will not replace it" — and splitting them across
      # two classes would make a script rescue twice for one concern.
      module Write
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")
          eof = Helpers.fetch(legate, interp, "EOF")

          register(interp, legate, broker, conflict, eof, clobber: false)
          register(interp, legate, broker, conflict, eof, clobber: true)
        end

        # One body, registered twice. `clobber` selects the name, the
        # risk profile and the destination rule; nothing else varies,
        # which is the point — a future change to the atomic-write
        # dance cannot land on one verb and miss the other.
        private def self.register(interp : Interpreter, legate : RubyClass, broker : Broker,
                                  conflict : RubyClass, eof : RubyClass, clobber : Bool) : Nil
          name = clobber ? "write!" : "write"

          profile = if clobber
                      # Replacing an existing file destroys its
                      # previous content irrecoverably, which is
                      # `DeletesFiles` in the same honest sense `mv!`
                      # carries it: a real loss of data the script
                      # never named as a target of deletion.
                      RiskProfile.new(
                        effects: Set{Effect::WritesFiles, Effect::DeletesFiles},
                        reversible: Reversibility::No,
                        severity: Severity::Warning,
                      )
                    else
                      RiskProfile.new(effects: Set{Effect::WritesFiles})
                    end

          legate.define_native_singleton_method(
            interp.symbols.intern(name).value,
            profile,
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string

            # `allow_missing: true` — a fresh write target NOT existing
            # yet is the NORMAL case (`authorize_write`'s own updated
            # comment, broker.cr), unlike every read-grant verb, where
            # a missing path is the recoverable exception rather than
            # the common case.
            broker.authorize_write(raw, ncc, allow_missing: true)

            check_destination(raw, name, clobber, ncc, conflict)

            dir = File.dirname(raw)
            # "Parent directories are created automatically" (§4.3) —
            # recursive AND idempotent, matching `mkdir`'s own
            # documented semantics one section down; a write into an
            # already-fully-existing directory is the common case and
            # this is a no-op for it.
            FileUtils.mkdir_p(dir)

            # `.legate-write-` prefix (not just a bare random name) —
            # purely cosmetic, so a `Legate.list`/`ls` on the
            # directory mid-write is recognizable as Legate's own
            # in-progress temp file, not a mystery file. The random
            # hex suffix is what actually prevents a collision between
            # two concurrent `Legate.write` calls targeting the same
            # directory.
            temp_path = File.join(dir, ".legate-write-#{Random::Secure.hex(8)}.tmp")
            data_val = args[2]? || Value.nil_value

            bytes_written = 0_i64
            begin
              File.open(temp_path, "wb") do |io|
                bytes_written = Helpers.write_io_data(io, data_val, ncc, broker, eof, "Legate.#{name}")
                io.flush
                # NOT independently verified against a live toolchain:
                # `IO::FileDescriptor#fsync` is written from
                # recollection of Crystal's own POSIX-`fsync(2)`
                # wrapper — same caveat this codebase already flags
                # for other stdlib-API assumptions (regexp.cr/time.cr)
                # — but §4.3's own text requires `fsync` explicitly, by
                # name, so skipping it isn't a reasonable fallback if
                # this turns out wrong; the method name is the thing
                # to correct, not the requirement itself.
                io.fsync
              end
              File.rename(temp_path, raw)
            rescue ex
              # Cleanup, not error translation — whatever `ex` actually
              # is (a budget-exhaustion `FatalSignal`, a wrong-type
              # `TypeError`, a raw Crystal IO error) propagates
              # completely unchanged after this; the ONLY job here is
              # making sure a failed write never leaves an orphaned
              # `.tmp` file behind, and — just as importantly — NEVER
              # reaches the `File.rename` above, so the REAL target
              # path is untouched by a failed write, at every possible
              # failure point.
              File.delete(temp_path) if File.exists?(temp_path)
              raise ex
            end

            Value.int(bytes_written)
          end
        end

        # The destination rule, and the only behavioural difference
        # between the two verbs.
        #
        # `follow_symlinks: false`, matching `rm.cr`/`mv.cr`'s stance,
        # but NOT for their security reason — verified against the
        # perimeter rather than assumed, 2026-09-03, after an earlier
        # draft of this comment claimed a hole that does not exist.
        # `check_root_maybe_missing` (grants.cr) realpaths the deepest
        # EXISTING ancestor, and a symlink is an existing entry, so a
        # link inside a granted write root pointing outside every root
        # resolves fully and is DENIED before this method is reached.
        # The perimeter already covers the escape case here, unlike in
        # `rm.cr`, where non-following is genuinely load-bearing.
        #
        # What the flag actually buys is the DANGLING link: a symlink
        # whose target does not exist resolves to a prospective
        # in-root path, so the broker allows it, and `File.info?` with
        # following would report nothing there and let the write
        # replace the link with a regular file. Not following means
        # the entry that is plainly sitting at the destination is the
        # one this verb answers about — which is the whole point of
        # the refusal. It also fixes the message wording, since a
        # followed link would describe the target's kind rather than
        # the destination's.
        #
        # `write!` keeps the one refusal the original verb already
        # made: a DIRECTORY target. No amount of atomic-rename
        # cleverness makes "write file content to a directory path" a
        # sensible operation, so this is not a replacement the bang
        # is offering to perform. Anything else structurally wrong
        # (e.g. a PARENT component existing as a plain file, blocking
        # `FileUtils.mkdir_p`) is still left to surface as whatever
        # raw Crystal error it produces — the same "small, accepted
        # edge window" judgment every read verb's `File.open` makes.
        private def self.check_destination(raw : String, name : String, clobber : Bool,
                                           ncc : NativeCallContext, conflict : RubyClass) : Nil
          info = File.info?(raw, follow_symlinks: false)
          return unless info

          if clobber
            if info.directory?
              ncc.raise_error_class("#{raw} is a directory; Legate.#{name} can't overwrite it with file content", conflict)
            end
            return
          end

          # Principle 6, "errors teach": the message names the verb
          # that would have worked, so a model reading only the
          # exception knows the fix without consulting the spec.
          kind = info.directory? ? "a directory" : "a file"
          ncc.raise_error_class(
            "#{raw} already exists and is #{kind}; Legate.#{name} won't replace it — use Legate.write! to overwrite",
            conflict,
          )
        end
      end
    end
  end
end
