require "file_utils"
require "../broker"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # The `delete` grant's three verbs (LEGATE.md §4.4):
      #
      #   Legate.rm(path)      -> Bool      # a file
      #   Legate.rmdir(path)   -> Bool      # an empty directory
      #   Legate.rmdir!(path)  -> Integer   # a tree; entries removed
      #
      # Three names rather than a `recursive:` flag, so the bang means
      # "the more destructive form" here as it does on `write!`, `cp!`
      # and `mv!`. A wrong choice raises `Legate::Conflict` naming the
      # verb that would work: `rm` on a directory points to `rmdir`,
      # `rmdir` on a file to `rm`, `rmdir` on a non-empty directory to
      # `rmdir!`.
      #
      # A missing path returns false or 0 (§2.3), after authorization,
      # so a missing path outside every delete root is still denied.
      #
      # Symlinks are never followed: these verbs remove the link, and
      # `rmdir!`'s walk doesn't descend into a symlinked directory,
      # which matters because only the tree's root is authorized. A
      # symlink named directly is already resolved by the perimeter.
      #
      # No byte budget applies; deletion reads and writes nothing. Each
      # verb declares its reversibility and severity explicitly.
      module Rm
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")

          register_rm(interp, legate, broker, conflict)
          register_rmdir(interp, legate, broker, conflict)
          register_rmdir_bang(interp, legate, broker, conflict)
        end

        # `Legate.rm(path) -> Bool`: true if a file was removed, false
        # if nothing was there.
        private def self.register_rm(interp : Interpreter, legate : RubyClass, broker : Broker,
                                     conflict : RubyClass) : Nil
          # A Delete sink, so a labelled path is checked against
          # policy as well as the path's own sensitivity.
          legate.define_native_singleton_method(
            interp.symbols.intern("rm").value,
            RiskProfile.new(
              effects: Set{Effect::DeletesFiles},
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
            authorities: Set{Authority::Delete},
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

        # `Legate.rmdir(path) -> Bool`: an empty directory only.
        private def self.register_rmdir(interp : Interpreter, legate : RubyClass, broker : Broker,
                                        conflict : RubyClass) : Nil
          # A Delete sink.
          legate.define_native_singleton_method(
            interp.symbols.intern("rmdir").value,
            RiskProfile.new(
              effects: Set{Effect::DeletesFiles},
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
            authorities: Set{Authority::Delete},
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

        # `Legate.rmdir!(path) -> Integer`: the whole tree. Declares
        # `Effect::Recursive`, which the name makes certain.
        private def self.register_rmdir_bang(interp : Interpreter, legate : RubyClass, broker : Broker,
                                             conflict : RubyClass) : Nil
          # A Delete sink.
          legate.define_native_singleton_method(
            interp.symbols.intern("rmdir!").value,
            RiskProfile.new(
              effects: Set{Effect::DeletesFiles, Effect::Recursive},
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
            authorities: Set{Authority::Delete},
          ) do |args, _blk, ncc|
            raw, label = target(args, ncc, broker)

            info = File.info?(raw, follow_symlinks: false)
            next Value.int(0_i64, label) unless info

            refuse_file(raw, info, "rmdir!", ncc, conflict)

            # Counted before removing, since `FileUtils.rm_rf` reports
            # nothing; a removal that fails partway raises instead of
            # returning the count.
            total = count_entries(raw)
            FileUtils.rm_rf(raw)
            Value.int(total, label)
          end
        end

        # The target path and its label, after authorization. A Bool or
        # count about a sensitive path still carries its label, since
        # existence and size are information too.
        private def self.target(args : Array(Value), ncc : NativeCallContext,
                                broker : Broker) : {String, RiskFlowLabel?}
          path_val = args[1]? || Value.nil_value
          str_val = ncc.call_method(path_val, "to_s", [] of Value)
          raw = str_val.as_string
          label = RiskFlowLabel.join(str_val.label, broker.authorize_delete(raw, ncc, allow_missing: true))
          {raw, label}
        end

        # Raises `Legate::Conflict` for a file given to a directory
        # verb, pointing to `rm`.
        private def self.refuse_file(raw : String, info : File::Info, name : String,
                                     ncc : NativeCallContext, conflict : RubyClass) : Nil
          return if info.directory?

          ncc.raise_error_class(
            "#{raw} is a file, not a directory; Legate.#{name} only removes directories — use Legate.rm",
            conflict,
          )
        end

        # Counts the directory and every descendant, dotfiles included,
        # a symlink as one entry and not descended into. `Dir.children`
        # rather than a glob, which skips dotfiles and needs `/`
        # separators.
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
