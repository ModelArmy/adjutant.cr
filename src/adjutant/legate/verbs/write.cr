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
      # `Legate.write(path, data) -> Integer` (bytes written) and
      # `Legate.write!` (LEGATE.md §4.3). `write` refuses an existing
      # destination; `write!` replaces a file. Both raise
      # `Legate::Conflict` for a directory at the path.
      #
      # Atomic, as §4.3 requires: a temp file in the same directory
      # (so the rename stays on one filesystem), fsync, rename. A crash
      # or budget exhaustion partway leaves the target as it was.
      #
      # `data` is a String, an Array of Strings or a Legate stream,
      # written one element at a time so a stream never materialises
      # (`Helpers.write_io_data`).
      module Write
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")
          eof = Helpers.fetch(legate, interp, "EOF")

          register(interp, legate, broker, conflict, eof, clobber: false)
          register(interp, legate, broker, conflict, eof, clobber: true)
        end

        # One body for both verbs; `clobber` selects the name, the risk
        # profile and the destination rule.
        private def self.register(interp : Interpreter, legate : RubyClass, broker : Broker,
                                  conflict : RubyClass, eof : RubyClass, clobber : Bool) : Nil
          name = clobber ? "write!" : "write"

          profile = if clobber
                      # `write!` declares DeletesFiles: the
                      # replaced file's content is gone.
                      RiskProfile.new(
                        effects: Set{Effect::WritesFiles, Effect::DeletesFiles},
                        reversible: Reversibility::No,
                        severity: Severity::Warning,
                      )
                    else
                      RiskProfile.new(effects: Set{Effect::WritesFiles})
                    end

          # A Write sink, so labelled data being written is checked
          # against policy; `authorize_write` checks only the
          # destination path's own sensitivity.
          legate.define_native_singleton_method(
            interp.symbols.intern(name).value,
            profile,
            authorities: Set{Authority::Write},
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string

            # A target that doesn't exist yet is the normal case.
            broker.authorize_write(raw, ncc, allow_missing: true)

            check_destination(raw, name, clobber, ncc, conflict)

            dir = File.dirname(raw)
            # Parent directories are created (§4.3).
            FileUtils.mkdir_p(dir)

            # A recognisable temp name with a random suffix, so
            # concurrent writes don't collide. `::Random::Secure`, since
            # this namespace's `Random` verb module hides the stdlib's.
            temp_path = File.join(dir, ".legate-write-#{::Random::Secure.hex(8)}.tmp")
            data_val = args[2]? || Value.nil_value

            bytes_written = 0_i64
            begin
              File.open(temp_path, "wb") do |io|
                bytes_written = Helpers.write_io_data(io, data_val, ncc, broker, eof, "Legate.#{name}")
                io.flush
                # §4.3 requires the fsync.
                io.fsync
              end
              File.rename(temp_path, raw)
            rescue ex
              # Removes the temp file and re-raises unchanged; the
              # rename is never reached, so the target is untouched.
              File.delete(temp_path) if File.exists?(temp_path)
              raise ex
            end

            Value.int(bytes_written)
          end
        end

        # The destination rule, the one difference between the verbs.
        # `write` refuses anything at the path; `write!` refuses only a
        # directory. Symlinks aren't followed, so a dangling link at
        # the destination counts as occupied; a link pointing outside
        # the roots is denied earlier by the perimeter. A parent path
        # component that is a file surfaces as a Crystal error from
        # `mkdir_p`.
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

          # The message names the verb that would work.
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
