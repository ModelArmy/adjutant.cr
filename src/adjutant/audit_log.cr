require "./authority"

module Adjutant
  # One broker decision (LEGATE.md §8.7). Written before the effect
  # runs, so it has no byte count or duration. `subject` is the
  # resolved path, host or binary. `decision` is `:allowed`,
  # `:denied` (the perimeter) or `:rejected` (the risk-flow policy).
  struct AuditRecord
    getter timestamp : Time
    getter verb : String
    getter subject : String
    getter authority : Authority
    getter decision : Symbol
    getter exception_class : String?

    def initialize(@verb : String, @subject : String, @authority : Authority, @decision : Symbol,
                   @exception_class : String? = nil, @timestamp : Time = Time.utc)
    end
  end

  # A run's audit records, in order and append-only. Writes nowhere:
  # the host reads `records` and decides format, destination and
  # redaction.
  class AuditLog
    getter records : Array(AuditRecord)

    def initialize
      @records = [] of AuditRecord
    end

    def append(record : AuditRecord) : Nil
      @records << record
    end
  end
end
