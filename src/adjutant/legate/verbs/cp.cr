require "file_utils"
require "../broker"
require "../path"
require "../tree_copy"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.cp(from, to, recursive: false) -> Legate::Path` and
      # `Legate.cp!` (LEGATE.md §4.3). `cp` refuses an occupied
      # destination; `cp!` replaces it, file or whole tree, never
      # merging as `cp -r` does. `recursive:` is about the source (may
      # a tree be walked), the bang about the destination (may what's
      # there be destroyed), so the two are independent.
      #
      # Additions to §4.3, which lists `cp` under the `write` grant
      # only:
      #   - `from` needs a `read` grant too, since copying reads it.
      #   - Parent directories of `to` are created, as for `write`.
      #   - A file copy is atomic, as `write` is: a temp file in `to`'s
      #     directory, fsync, rename.
      #
      # A recursive copy never follows a symlink inside the tree; it
      # recreates the link (see `TreeCopy`).
      module Cp
        # Copy chunk size, as bytes.cr's; both budgets are checked
        # after each chunk.
        COPY_CHUNK_SIZE = 65_536

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          conflict = Helpers.fetch(legate, interp, "Conflict")
          path_cls = Helpers.fetch(legate, interp, "Path")

          register(interp, legate, broker, not_found, conflict, path_cls, clobber: false)
          register(interp, legate, broker, not_found, conflict, path_cls, clobber: true)
        end

        # One body for both verbs; `clobber` selects the name, the risk
        # profile and the destination rule.
        private def self.register(interp : Interpreter, legate : RubyClass, broker : Broker,
                                  not_found : RubyClass, conflict : RubyClass, path_cls : RubyClass,
                                  clobber : Bool) : Nil
          name = clobber ? "cp!" : "cp"

          profile = if clobber
                      # `cp!` declares DeletesFiles: a replaced file's
                      # content, or a replaced tree, is gone.
                      RiskProfile.new(
                        effects: Set{Effect::ReadsFiles, Effect::WritesFiles, Effect::DeletesFiles},
                        reversible: Reversibility::No,
                        severity: Severity::Warning,
                      )
                    else
                      RiskProfile.new(effects: Set{Effect::ReadsFiles, Effect::WritesFiles})
                    end

          # A Write sink. Both arguments are paths: the copy goes
          # file to file, so no content passes through the VM for a
          # label to travel on.
          legate.define_native_singleton_method(
            interp.symbols.intern(name).value,
            profile,
            Set{"recursive"},
            authorities: Set{Authority::Write},
          ) do |args, _blk, ncc|
            recursive = recursive_flag(ncc, name)

            from_val = args[1]? || Value.nil_value
            from_str_val = ncc.call_method(from_val, "to_s", [] of Value)
            raw_from = from_str_val.as_string

            to_val = args[2]? || Value.nil_value
            to_str_val = ncc.call_method(to_val, "to_s", [] of Value)
            raw_to = to_str_val.as_string
            label = RiskFlowLabel.join(from_str_val.label, to_str_val.label)

            # A missing source inside a granted read root is
            # `Legate::NotFound`, not a denial.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw_from, ncc, allow_missing: true))
            # `to` not existing yet is the normal case.
            label = RiskFlowLabel.join(label, broker.authorize_write(raw_to, ncc, allow_missing: true))

            # Follows symlinks: `cp` copies content, as `read` does.
            from_info = File.info?(raw_from, follow_symlinks: true)
            unless from_info
              ncc.raise_error_class("#{raw_from} not found", not_found)
            end

            if from_info.directory?
              label = RiskFlowLabel.join(label, copy_directory(raw_from, raw_to, recursive, broker, ncc, conflict, name, clobber))
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

        # For `cp`: raises `Legate::Conflict` if anything, even a
        # dangling symlink, is at `to`. Not following symlinks is what
        # catches the dangling one. Checked after the source checks, so
        # a wrong `recursive:` is reported first.
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

        # A directory source needs `recursive: true`, so a whole tree is
        # never copied by accident. The tree is built in a temp directory
        # beside `to`, then renamed into place. Each file is authorized
        # as a read of its own as the walk reaches it, so it is checked,
        # labelled and audited as `Legate.read` would be; returns the
        # files' labels joined.
        private def self.copy_directory(raw_from : String, raw_to : String, recursive : Bool,
                                        broker : Broker, ncc : NativeCallContext, conflict : RubyClass,
                                        name : String, clobber : Bool) : RiskFlowLabel?
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
          # `::Random::Secure`, since this namespace's `Random` verb
          # module hides the stdlib's.
          temp_dir = File.join(dest_parent, ".legate-cp-#{::Random::Secure.hex(8)}.tmp")
          label : RiskFlowLabel? = nil
          copier = TreeCopy.new(broker.budget) do |file|
            label = RiskFlowLabel.join(label, broker.authorize_read(file, ncc))
            nil
          end
          begin
            Dir.mkdir(temp_dir)
            copier.copy_children(raw_from, temp_dir)
            # Renaming a directory is atomic on one filesystem, which is
            # why the temp directory sits in `to`'s parent. An existing
            # tree at `to` is removed first: `cp!` replaces, never
            # merges.
            FileUtils.rm_rf(raw_to) if File.directory?(raw_to)
            File.rename(temp_dir, raw_to)
          rescue ex
            FileUtils.rm_rf(temp_dir) if File.exists?(temp_dir)
            if ex.is_a?(TreeCopy::SpecialFile)
              ncc.raise_error_class("#{ex.message}; Legate.#{name} can't copy it", conflict)
            end
            raise ex
          end
          label
        end

        # Copies one file atomically (temp file, fsync, rename) in
        # `COPY_CHUNK_SIZE` pieces, as bytes, recording the read and
        # write budgets per chunk.
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
          # `::Random::Secure`; see `copy_directory`.
          temp_path = File.join(dest_dir, ".legate-cp-#{::Random::Secure.hex(8)}.tmp")

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
