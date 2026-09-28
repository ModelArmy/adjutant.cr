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
      # `Legate.mv(from, to) -> Legate::Path` and `Legate.mv!`
      # (LEGATE.md §4.4). `mv` refuses an occupied destination; `mv!`
      # replaces a file with a file and nothing else.
      #
      # An addition to §4.4, which gates `mv` on `delete` alone: `to`
      # needs a `write` grant too, since a move creates content there.
      # Otherwise a script with `delete` but no `write` could place
      # files outside every write root. The grants stay separable both
      # ways, as §4.4 argues for `write` without `delete`.
      #
      # `mv` declares MovesFiles alone, reversible and Info: a move
      # destroys nothing, on one filesystem or across two. Needing
      # Delete and Write authority is about what it may do, not what
      # it does. `mv!` adds DeletesFiles for the file it replaces.
      module Mv
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
          name = clobber ? "mv!" : "mv"

          profile = if clobber
                      RiskProfile.new(
                        effects: Set{Effect::MovesFiles, Effect::DeletesFiles},
                        reversible: Reversibility::No,
                        severity: Severity::Warning,
                      )
                    else
                      # Reversible and Info by default.
                      RiskProfile.new(effects: Set{Effect::MovesFiles})
                    end

          # Delete and Write sinks, matching the two authorizations
          # below.
          legate.define_native_singleton_method(
            interp.symbols.intern(name).value,
            profile,
            authorities: Set{Authority::Delete, Authority::Write},
          ) do |args, _blk, ncc|
            from_val = args[1]? || Value.nil_value
            from_str_val = ncc.call_method(from_val, "to_s", [] of Value)
            raw_from = from_str_val.as_string

            to_val = args[2]? || Value.nil_value
            to_str_val = ncc.call_method(to_val, "to_s", [] of Value)
            raw_to = to_str_val.as_string
            label = RiskFlowLabel.join(from_str_val.label, to_str_val.label)

            # A missing source inside a granted root is
            # `Legate::NotFound` (§4.4), not a denial; `rm` returns 0
            # for the same case.
            label = RiskFlowLabel.join(label, broker.authorize_delete(raw_from, ncc, allow_missing: true))
            # `to` not existing yet is the normal case.
            label = RiskFlowLabel.join(label, broker.authorize_write(raw_to, ncc, allow_missing: true))

            # Doesn't follow symlinks: a symlink `from` moves the link
            # itself.
            from_info = File.info?(raw_from, follow_symlinks: false)
            unless from_info
              ncc.raise_error_class("#{raw_from} not found", not_found)
            end

            check_destination(raw_from, raw_to, from_info.directory?, ncc, conflict, name, clobber)

            # Parent directories of `to` are created, as `write` and
            # `cp` do (§4.3).
            FileUtils.mkdir_p(File.dirname(raw_to))

            relocate(raw_from, raw_to, broker, ncc, conflict, name)

            Legate::Path.from_string(interp, path_cls, ::Path.new(raw_to).to_posix.to_s, label)
          end
        end

        # Refuses an occupied destination, symlinks not followed. `mv!`
        # lifts only the file-over-file refusal.
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

          # A file never replaces a directory, nor the reverse.
          if to_is_dir != from_is_dir
            kind = to_is_dir ? "a directory" : "a file"
            ncc.raise_error_class("#{raw_to} exists and is #{kind}; Legate.#{name} can't replace it with #{raw_from}", conflict)
          end

          # No directory is ever replaced, empty or not, so the result
          # doesn't depend on the platform: POSIX `rename(2)` replaces an
          # empty directory and Windows `MoveFile` refuses. To replace
          # one, use `Legate.rmdir` then `Legate.mv`.
          if to_is_dir
            ncc.raise_error_class(
              "#{raw_to} is a directory; Legate.#{name} won't replace one — remove it first with Legate.rmdir, then move",
              conflict,
            )
          end
        end

        # `File.rename` when both paths share a filesystem: atomic, no
        # bytes moved, no budget used. On `EXDEV` (`File::Error`'s
        # `os_error`), falls back to copy then delete.
        private def self.relocate(raw_from : String, raw_to : String, broker : Broker,
                                  ncc : NativeCallContext, conflict : RubyClass, name : String) : Nil
          File.rename(raw_from, raw_to)
        rescue ex : File::Error
          raise ex unless ex.os_error == Errno::EXDEV
          # Not atomic: a failure partway leaves the source whole and a
          # partial destination, since the source is deleted only after
          # the copy succeeds. Unlike a rename, this uses read and write
          # budget. As a rename would, `mv!` replaces a file or symlink
          # at `to` rather than writing through it.
          if (to_info = File.info?(raw_to, follow_symlinks: false)) && !to_info.directory?
            File.delete(raw_to)
          end
          begin
            TreeCopy.new(broker.budget) { }.copy_entry(raw_from, raw_to)
          rescue e : TreeCopy::SpecialFile
            ncc.raise_error_class("#{e.message}; Legate.#{name} can't move it across filesystems", conflict)
          end
          FileUtils.rm_rf(raw_from)
        end
      end
    end
  end
end
