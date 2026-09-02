require "../budget"

module Adjutant
  module Legate
    # `Budget` moved to core on 2026-09-01 — it counts bytes and
    # seconds, which is not a verb-shaped problem. See
    # `src/adjutant/budget.cr`.
    #
    # Aliased at the old name so verbs, the broker and the existing
    # specs keep referring to `Legate::Budget`.
    alias Budget = ::Adjutant::Budget
  end
end
