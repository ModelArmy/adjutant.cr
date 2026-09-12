require "../audit_log"

module Adjutant
  module Legate
    # `AuditRecord` and `AuditLog` moved to core on 2026-09-01, along
    # with the broker sequence that appends them — one audit log per
    # RUN, not per provider. `AuditRecord#grant : Symbol` became
    # `#authority : Authority` in the same change; see
    # `src/adjutant/audit_log.cr`.
    #
    # Aliased at the old names so the existing specs and any embedder
    # reading `broker.audit_log.records` keep working.
    alias AuditRecord = ::Adjutant::AuditRecord
    alias AuditLog = ::Adjutant::AuditLog
  end
end
