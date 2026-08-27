require "file_utils"
require "../broker"
require "../path"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.mkdir(path) -> Legate::Path` — LEGATE.md §4.3. "always
      # recursive and always idempotent — it succeeds on an existing
      # directory, removing the `unless exist?` dance from every
      # script" (§4.3's own words) — `FileUtils.mkdir_p` already has
      # exactly both properties natively (recursive AND a no-op if the
      # target already exists as a directory), so this verb is mostly
      # authorization/error-mapping around one stdlib call, not new
      # logic of its own.
      module Mkdir
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          conflict = Helpers.fetch(legate, interp, "Conflict")
          path_cls = Helpers.fetch(legate, interp, "Path")

          legate.define_native_singleton_method(
            interp.symbols.intern("mkdir").value,
            RiskProfile.new(tags: Set{RiskTag::WritesFiles}),
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # `allow_missing: true` — the whole point of `mkdir` is
            # usually creating a path that DOESN'T exist yet; same
            # reasoning as `write.cr`/`append.cr`'s identical line.
            label = RiskFlowLabel.join(label, broker.authorize_write(raw, ncc, allow_missing: true))

            # The one real `Legate::Conflict` case here: something
            # already exists at `raw`, but it's a FILE, not a
            # directory — "idempotent" means safely re-running
            # `mkdir` on a directory that's already there, NOT
            # silently accepting a completely different kind of thing
            # occupying that path. `FileUtils.mkdir_p` itself would
            # raise its own raw Crystal error for this case; checking
            # explicitly first gives a clean, on-brand `Legate::
            # Conflict` instead.
            if File.exists?(raw) && !File.directory?(raw)
              ncc.raise_error_class("#{raw} exists and is not a directory; Legate.mkdir can't create a directory there", conflict)
            end

            FileUtils.mkdir_p(raw)

            # `::Path.new(...).to_posix` before building the RETURNED
            # `Legate::Path` — not because `raw` came from `Dir.glob`
            # this time (it's the script's OWN argument, already
            # `.to_s`'d), but for the same underlying reason list.cr/
            # grep.cr's own identical normalization exists: a script
            # could easily have built `raw` from a `\`-joined source
            # on Windows (string interpolation, `ENV["TEMP"]`, etc.),
            # and `Legate::Path` splits ONLY on `/` by design
            # (path.cr) — normalizing here means the `Path` this verb
            # HANDS BACK is guaranteed splittable/basename-able
            # regardless of how the caller happened to spell it.
            Legate::Path.from_string(interp, path_cls, ::Path.new(raw).to_posix.to_s, label)
          end
        end
      end
    end
  end
end
