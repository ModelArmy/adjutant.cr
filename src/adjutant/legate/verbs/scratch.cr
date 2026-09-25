require "../broker"
require "../path"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.scratch -> Legate::Path` (LEGATE.md §4.7): a temp
      # directory granted by default, so incidental working space
      # needs no write grant. Created on first call and the same for
      # the whole run; removed when the `eval` ends (see
      # `Broker#scratch_dir`). No authorization here: reads, writes and
      # deletes inside it are authorized normally, with the scratch
      # path added to the roots (`Broker#ambient_roots`). Declares
      # `Effect::WritesFiles`, since it creates a directory.
      module Scratch
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          path_cls = Helpers.fetch(legate, interp, "Path")

          legate.define_native_singleton_method(
            interp.symbols.intern("scratch").value,
            RiskProfile.new(effects: Set{Effect::WritesFiles}),
          ) do |_args, _blk, _ncc|
            # `/` separators, as Legate::Path needs, and no label: the
            # path is system-generated.
            posix = ::Path.new(broker.scratch_dir).to_posix.to_s
            Legate::Path.from_string(interp, path_cls, posix, nil)
          end
        end
      end
    end
  end
end
