require "file_utils"
require "../broker"
require "../path"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.mkdir(path) -> Legate::Path` (LEGATE.md §4.3): always
      # recursive and idempotent, as `FileUtils.mkdir_p` is.
      module Mkdir
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")
          path_cls = Helpers.fetch(legate, interp, "Path")

          # A Write sink, so a labelled path is checked against
          # policy. There's no data argument.
          legate.define_native_singleton_method(
            interp.symbols.intern("mkdir").value,
            RiskProfile.new(effects: Set{Effect::WritesFiles}),
            authorities: Set{Authority::Write},
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # A path that doesn't exist yet is the normal case.
            label = RiskFlowLabel.join(label, broker.authorize_write(raw, ncc, allow_missing: true))

            # A file at the path raises `Legate::Conflict`; idempotent
            # means an existing directory, not anything at all.
            if File.exists?(raw) && !File.directory?(raw)
              ncc.raise_error_class("#{raw} exists and is not a directory; Legate.mkdir can't create a directory there", conflict)
            end

            FileUtils.mkdir_p(raw)

            # The returned Legate::Path uses `/` separators, whatever
            # the script passed, since Legate::Path splits on `/` only.
            Legate::Path.from_string(interp, path_cls, ::Path.new(raw).to_posix.to_s, label)
          end
        end
      end
    end
  end
end
