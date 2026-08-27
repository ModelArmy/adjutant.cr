require "file_utils"
require "../broker"
require "../stream"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.append(path, data) -> Integer` (bytes appended) —
      # LEGATE.md §4.3, sharing that section's prose with `write`
      # (parent directories created automatically; `data` is a String
      # or any Enumerable of Strings, including a Legate stream;
      # `Conflict`/`Exhausted` raised the same way) — but NOT §4.3's
      # `write`-specific "MUST be atomic: temporary file... `fsync`...
      # `rename`" sentence, which names `write` alone, not this verb.
      #
      # That's not an oversight to fix — it's a real, load-bearing
      # difference: `write`'s atomicity is about replacing a file's
      # ENTIRE content without ever exposing a half-written mix of old
      # and new. `append` has no "old vs new" content to keep separate
      # in the first place — the existing bytes on disk are simply the
      # start of what the file will contain either way. A failure
      # PARTWAY through an append (a bad element type, budget
      # exhaustion) leaves fewer bytes appended than intended, but
      # never a CORRUPTED mix the way an interrupted whole-file
      # rewrite could — so there's nothing for a temp-file/rename dance
      # to protect against here, and LEGATE.md's own text reflects
      # that by only requiring it of `write`.
      #
      # Real, worth-naming consequence of NOT being atomic: unlike
      # `write` (proven in write_spec.cr — a failed write leaves a
      # PRE-EXISTING target completely untouched), a failed `append`
      # CAN leave a partial write behind — whatever pieces of `data`
      # were already flushed to disk before the failure stay there.
      module Append
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")
          eof = Helpers.fetch(legate, interp, "EOF")

          legate.define_native_singleton_method(
            interp.symbols.intern("append").value,
            RiskProfile.new(tags: Set{RiskTag::WritesFiles}),
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string

            # `allow_missing: true` — same reasoning as `write.cr`'s
            # identical line: appending to a path that doesn't exist
            # yet is completely normal (mode `"a"` below creates it),
            # not the exceptional case.
            broker.authorize_write(raw, ncc, allow_missing: true)

            # Same one `Legate::Conflict` case `write.cr` checks for,
            # same reasoning — see that file's own comment.
            if File.directory?(raw)
              ncc.raise_error_class("#{raw} is a directory; Legate.append can't write file content to it", conflict)
            end

            # "Parent directories are created automatically" (§4.3,
            # shared with `write`) — same call, same reasoning as
            # write.cr's own identical line.
            FileUtils.mkdir_p(File.dirname(raw))

            data_val = args[2]? || Value.nil_value
            # Mode `"a"` — POSIX `O_APPEND` semantics (create if
            # missing, every write lands at the CURRENT end of file,
            # even if another process/write moved it since this file
            # handle was opened) — the real mechanism this verb's own
            # name promises, not `"r+"` plus a manual seek-to-end
            # (which has a TOCTOU gap `O_APPEND` itself doesn't).
            bytes_written = File.open(raw, "a") do |io|
              Helpers.write_io_data(io, data_val, ncc, broker, eof, "Legate.append")
            end

            Value.int(bytes_written)
          end
        end
      end
    end
  end
end
