require "../budget"

module Adjutant
  module Legate
    # Core's Budget under a Legate name, used by the verbs, the broker
    # and specs.
    alias Budget = ::Adjutant::Budget
  end
end
