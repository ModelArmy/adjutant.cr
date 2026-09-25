require "file_utils"
require "../broker"
require "../stream"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.append(path, data) -> Integer` (bytes appended)
      # (LEGATE.md §4.3): parent directories created and `data` shaped
      # as for `write`. Not atomic, and §4.3 doesn't ask it to be: a
      # failure partway leaves the bytes already written, but never a
      # mix of old and new content, so there is nothing for a
      # temp-file rename to protect.
      module Append
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")
          eof = Helpers.fetch(legate, interp, "EOF")

          # A Write sink; see write.cr.
          legate.define_native_singleton_method(
            interp.symbols.intern("append").value,
            RiskProfile.new(effects: Set{Effect::WritesFiles}),
            authorities: Set{Authority::Write},
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string

            # A target that doesn't exist yet is normal; mode "a"
            # creates it.
            broker.authorize_write(raw, ncc, allow_missing: true)

            # A directory at the path raises `Legate::Conflict`. This
            # follows symlinks, and so does the open below, so a
            # dangling link at the path is written through.
            if File.directory?(raw)
              ncc.raise_error_class("#{raw} is a directory; Legate.append can't write file content to it", conflict)
            end

            # Parent directories are created (§4.3).
            FileUtils.mkdir_p(File.dirname(raw))

            data_val = args[2]? || Value.nil_value
            # Mode "a" is `O_APPEND`: every write lands at the current
            # end of file, with no seek race.
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
