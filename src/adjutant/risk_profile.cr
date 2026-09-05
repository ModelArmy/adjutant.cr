require "./diagnostic"

module Adjutant
  # What a native function does to the world outside the VM.
  #
  # An Effect is a *consequence* — the reason a function is risky.
  # Reversibility and Severity (below) are *conclusions* drawn from
  # them. A RiskProfile with no effects must therefore be fully safe
  # (see RiskProfile's strict-empty rule) — if a function needs a
  # non-default reversibility or severity but has no effect to justify
  # it, that means an effect is missing, not that the conclusion fields
  # should be set freely.
  #
  # Deliberately NOT the same vocabulary as the authority a call
  # exercises: a move requires both delete and write authority, but
  # destroys nothing. See Authority for that half.
  enum Effect
    ReadsFiles
    WritesFiles
    DeletesFiles
    # Relocation, which is NOT destruction. `Legate.mv` carries this
    # ALONE and declares itself reversible: `File.rename` preserves
    # the information, and the cross-device fallback is deliberately
    # ordered copy-then-delete so a partway failure duplicates rather
    # than loses. Saying `DeletesFiles` of a move would imply a loss
    # that does not occur, and pairing the two is worse than either.
    #
    # `Legate.mv!` carries this AND `DeletesFiles`, the latter
    # honestly about the clobbered destination — a real,
    # unrecoverable loss of a file the script never named as a
    # source. That asymmetry with the AUTHORITY a move needs (both
    # Delete and Write, either way) is correct rather than an
    # oversight: authorities answer "what may this call do", effects
    # answer "what did it consequently do", and nothing infers one
    # from the other.
    MovesFiles
    Recursive
    ExecutesCode
    NetworkEgress
    ElevatedPrivilege
    ModifiesEnvironment
  end

  # Whether a native call's effect can be undone.
  #
  # `Depends` means reversibility is determined by call-site arguments
  # the static RiskProfile can't see (e.g. a flag toggling in-place
  # writes) — requires `note` to explain the condition. Phase A treats
  # `Depends` as "escalate and ask a human"; resolving it precisely is
  # deferred to argument-level analysis (Phase B/C).
  enum Reversibility
    Yes
    No
    Depends
  end

  # Precomputed severity for presentation — avoids re-deriving a summary
  # verdict from effects every time a risk manifest is displayed.
  enum Severity
    Info
    Warning
    Error
  end

  # Static, per-function risk metadata attached to a NativeCallable.
  #
  # Immutable value type. `RiskProfile.none` is the common case — most
  # native functions (arithmetic, string/array helpers, etc.) have no
  # side effects at all.
  #
  # An empty effect set strictly implies Reversibility::Yes and
  # Severity::Info; constructing an empty profile with any other
  # reversibility or severity is a bug in the caller and raises
  # immediately. If a function needs to express risk with no existing
  # effect fitting, add a new Effect rather than bypassing this check.
  struct RiskProfile
    getter effects : Set(Effect)
    getter reversible : Reversibility
    getter severity : Severity
    getter note : String?

    def initialize(@effects = Set(Effect).new,
                   @reversible = Reversibility::Yes,
                   @severity = Severity::Info,
                   @note = nil)
      if @effects.empty? && (!@reversible.yes? || !@severity.info?)
        raise HostArgumentError.new(Diagnostic.new(code: "H001"))
      end
      if @reversible.depends? && @note.nil?
        raise HostArgumentError.new(Diagnostic.new(code: "H002"))
      end
    end

    # The no-side-effects case: no effects, fully reversible, informational.
    def self.none : RiskProfile
      RiskProfile.new
    end
  end
end
