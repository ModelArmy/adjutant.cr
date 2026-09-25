require "../audit_log"

module Adjutant
  module Legate
    # Core's AuditRecord and AuditLog under Legate names, used by specs
    # and hosts reading `broker.audit_log.records`.
    # reading `broker.audit_log.records` keep working.
    alias AuditRecord = ::Adjutant::AuditRecord
    alias AuditLog = ::Adjutant::AuditLog
  end
end
