require "../open_sources"

module Adjutant
  module Legate
    # `Closable` and `OpenSources` moved to core on 2026-09-01 — a
    # registry of things needing closing at the end of a run says
    # nothing about Legate, and `Interpreter#eval` already owned the
    # teardown. See `src/adjutant/open_sources.cr`.
    #
    # Aliased at the old names so every `Legate::Closable` include in
    # the stream verbs, and every `require "./open_sources"` alongside
    # them, keeps reading as it did.
    alias Closable = ::Adjutant::Closable
    alias OpenSources = ::Adjutant::OpenSources
  end
end
