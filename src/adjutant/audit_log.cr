require "./authority"

module Adjutant
  # A single audit record (LEGATE.md §8.7) — one per verb-boundary decision the
  # broker makes. Deliberately narrower than §8.7's full wishlist
  # for now: `bytes`/`duration` are absent because the BROKER is
  # consulted BEFORE a verb's effect happens and has no byte count
  # or elapsed time to report yet — those belong to whatever the
  # verb surface (step 5) adds once a verb actually knows them, not
  # to this pre-effect decision record. `subject` covers §8.7's
  # "arguments (paths canonicalised...)" for the one argument the
  # broker actually resolves (a path/host/binary); "bodies hashed
  # not stored" has no meaning yet either, for the same reason — no
  # verb has a body to hash until step 5.
  #
  # `decision` is one of `:allowed`, `:denied` (the static perimeter
  # gate), or `:rejected` (RiskFlowPolicy's dynamic layer, reached
  # only after `:denied` was ruled out — see broker.cr's own ordering
  # comment).
  #
  # `authority` is the permission consulted. It was a bare Symbol
  # (`:read`, `:write`, ...) until 2026-09-01, alongside an
  # `Authority` argument that said the same thing — `Broker#authorize`
  # took both. One of them had to go, and the typed one is the one
  # `RiskFlowRule` already keys on.
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

  # In-memory §8.7 audit log — one per Broker (so, one per run).
  # Append-only; nothing here ever removes or rewrites a record,
  # matching an audit log's own reason for existing. Deliberately
  # does NOT write to a file, stdout, or any other sink on its
  # own — §8.7 says the log "should be readable without the
  # script," which is a presentation/embedder concern (format,
  # destination, redaction) this class has no business deciding;
  # `records` is the ordered history an embedder reads and renders
  # however they need to.
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
