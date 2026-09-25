require "../broker"
require "../stat"
require "../helpers"
require "../../native_call_context"
require "../../builtins/time"

module Adjutant
  module Legate
    module Verbs
      # `Legate.stat(path) -> Legate::Stat | nil` (LEGATE.md §4.1).
      # The path may be a String or a Legate::Path; its `to_s` is
      # dispatched, so either one's label carries through.
      module Stat
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          stat_cls = Helpers.fetch(legate, interp, "Stat")

          # Both risk-flow checks apply: `authorities:` makes
          # `VM#check_risk_flow` check an argument that arrives
          # labelled, and `authorize_read` calls `declare_sensitivity`
          # on the path's own text, labelled or not. `risk:` only
          # feeds the static risk walk.
          legate.define_native_singleton_method(
            interp.symbols.intern("stat").value,
            RiskProfile.new(effects: Set{Effect::ReadsFiles}),
            authorities: Set{Authority::Read},
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # Nil for a missing path (§2.3), but a path outside every
            # root is still denied, so containment is checked before
            # existence (`allow_missing`). The result's label joins the
            # path argument's with the one policy gives the path.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))

            info = File.info?(raw, follow_symlinks: false)
            next Value.nil_value unless info

            Legate::Stat.build(interp, stat_cls, type_of(info), info.size, mtime_of(interp, info), mode_of(info), label)
          end
        end

        # `:file`, `:dir`, `:symlink` or `:other` (§5.2), without
        # following a final symlink, so a symlink is reported as one.
        # Authorization still resolves symlinks for containment.
        private def self.type_of(info : File::Info) : Symbol
          case info.type
          when File::Type::File      then :file
          when File::Type::Directory then :dir
          when File::Type::Symlink   then :symlink
          else                            :other
          end
        end

        # The permission bits.
        private def self.mode_of(info : File::Info) : Int32
          info.permissions.value.to_i32
        end

        # Unlabelled; the Stat carries the path's label.
        private def self.mtime_of(interp : Interpreter, info : File::Info) : Value
          time_cls = interp.get_global("Time").as_rclass
          Value.robject(TimeObject.new(time_cls, info.modification_time))
        end
      end
    end
  end
end
