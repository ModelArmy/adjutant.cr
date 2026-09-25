module Adjutant
  # A fatal condition from whatever enforces a run's limits: a denied
  # grant, an exhausted budget, a script's own abort. `kind` is
  # `:denied`, `:exhausted` or `:aborted`, named `Legate::Denied`,
  # `Legate::Exhausted` and `Legate::Aborted` in reports.
  #
  # A plain Exception, not a RuntimeError, so no script `rescue` can
  # catch it, `rescue Exception` included: the VM's dispatch loop
  # rescues only RuntimeError, and `call_native` re-raises a
  # FatalSignal before its catch-all turns anything else into N001.
  # An enforcer's fatal error must be a FatalSignal, or it becomes a
  # catchable N001. `Legate::FatalSignal` is an alias.
  class FatalSignal < Exception
    getter kind : Symbol
    getter data : Hash(String, String)

    def initialize(@kind : Symbol, message : String, @data = Hash(String, String).new)
      super(message)
    end
  end
end
