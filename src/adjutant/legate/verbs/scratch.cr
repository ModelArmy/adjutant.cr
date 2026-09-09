require "../broker"
require "../path"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.scratch -> Legate::Path` — LEGATE.md §4.7. A writable
      # temp directory, pre-granted (ambient, not gated by a `write:`
      # root) so a script needing incidental working space does not
      # have to be handed a broader write grant just for that. Lazily
      # created on first call (`Legate::Broker#scratch_dir`) — the
      # SAME directory for every call within one run — and removed at
      # the end of THIS `eval`; see that method's own comment
      # (`legate/broker.cr`) for the full per-eval-not-per-session
      # lifetime reasoning.
      #
      # No `authorize_write` call here, and deliberately so: creating
      # (or returning) the scratch directory itself needs no
      # authorization to consult, because §4.7 makes it unconditional
      # — "granted by default" IS the answer, not a question this
      # verb asks the broker. Authorization still happens normally
      # the moment a script actually writes/reads/deletes INSIDE
      # scratch, via `Legate::Broker#ambient_roots` folding the
      # scratch path into every `authorize_read`/`authorize_write`/
      # `authorize_delete` check from here on.
      #
      # `Effect::WritesFiles` is still declared, though nothing here
      # is grant-gated: the static risk sweep (step 4c) reports what a
      # script actually DOES to the world, independent of how that
      # doing was authorized, and creating a directory is real
      # filesystem activity a report reader should see regardless.
      module Scratch
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          path_cls = Helpers.fetch(legate, interp, "Path")

          legate.define_native_singleton_method(
            interp.symbols.intern("scratch").value,
            RiskProfile.new(effects: Set{Effect::WritesFiles}),
          ) do |_args, _blk, _ncc|
            # `::Path.new(...).to_posix` for the same reason mkdir.cr
            # normalizes its own returned Path: `File.tempname` builds
            # an OS-native path, `\`-joined on Windows, and
            # `Legate::Path` splits only on `/` by design (path.cr).
            # No incoming label to propagate — this path is entirely
            # system-generated, not derived from anything a script
            # supplied.
            posix = ::Path.new(broker.scratch_dir).to_posix.to_s
            Legate::Path.from_string(interp, path_cls, posix, nil)
          end
        end
      end
    end
  end
end
