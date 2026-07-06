module Adjutant
  # Intrinsic risk categories a native function's effect can fall into.
  #
  # Tags are the *reason* a function is risky; Reversibility and Severity
  # (below) are *conclusions* drawn from them. A RiskProfile with no tags
  # must therefore be fully safe (see RiskProfile's strict-empty rule) —
  # if a function needs a non-default reversibility or severity but has
  # no tag to justify it, that means a tag is missing, not that the
  # conclusion fields should be set freely.
  enum RiskTag
    ReadsFiles
    WritesFiles
    DeletesFiles
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
  # verdict from tags every time a risk manifest is displayed.
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
  # Empty tags strictly implies Reversibility::Yes and Severity::Info;
  # constructing an empty-tag profile with any other reversibility or
  # severity is a bug in the caller and raises immediately. If a
  # function needs to express risk with no existing tag fitting, add a
  # new RiskTag rather than bypassing this check.
  struct RiskProfile
    getter tags : Set(RiskTag)
    getter reversible : Reversibility
    getter severity : Severity
    getter note : String?

    def initialize(@tags = Set(RiskTag).new,
                   @reversible = Reversibility::Yes,
                   @severity = Severity::Info,
                   @note = nil)
      if @tags.empty? && (!@reversible.yes? || !@severity.info?)
        raise ArgumentError.new(
          "RiskProfile with no tags must have reversible: Yes and severity: Info " \
          "— add a RiskTag instead of setting these directly")
      end
      if @reversible.depends? && @note.nil?
        raise ArgumentError.new("RiskProfile: note is required when reversible is Depends")
      end
    end

    # The no-side-effects case: no tags, fully reversible, informational.
    def self.none : RiskProfile
      RiskProfile.new
    end
  end
end
