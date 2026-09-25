require "../open_sources"

module Adjutant
  module Legate
    # Core's Closable and OpenSources under Legate names, used by the
    # stream verbs.
    alias Closable = ::Adjutant::Closable
    alias OpenSources = ::Adjutant::OpenSources
  end
end
