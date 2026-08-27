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
      module Write
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")
          eof = Helpers.fetch(legate, interp, "EOF")

          legate.define_native_singleton_method(
            interp.symbols.intern("write").value,
            RiskProfile.new(tags: Set{RiskTag::WritesFiles}),
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

            # The one real `Legate::Conflict` case this verb checks
            # for PROACTIVELY, before touching anything: the target
            # already exists but is a DIRECTORY, not a file — no
            # amount of atomic-rename cleverness makes "write file
            # content to a directory path" a sensible operation.
            # Anything else structurally wrong (e.g. a PARENT
            # component existing as a plain file, blocking
            # `FileUtils.mkdir_p` below) is left to surface as
            # whatever raw Crystal error that produces — the same
            # "small, accepted race/edge window, not worth
            # over-engineering a remap for" judgment call every read
            # verb's own `File.open` already makes.
            if File.directory?(raw)
              ncc.raise_error_class("#{raw} is a directory; Legate.write can't overwrite it with file content", conflict)
            end

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
                bytes_written = Helpers.write_io_data(io, data_val, ncc, broker, eof, "Legate.write")
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
      end
    end
  end
end
