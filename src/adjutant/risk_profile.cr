require "./diagnostic"

module Adjutant
  # What a native function does to the world outside the VM: the
  # consequences that make it risky. Reversibility and Severity are
  # conclusions drawn from them, so a profile with no effects must be
  # fully safe; a function that needs another conclusion is missing an
  # effect. Separate from Authority, what a call may do: a move needs
  # Delete and Write authority but destroys nothing.
  enum Effect
    ReadsFiles
    WritesFiles
    DeletesFiles
    # Relocation, which destroys nothing. `Legate.mv` carries it alone
    # and is reversible: a cross-device move copies before deleting.
    # `Legate.mv!` adds DeletesFiles for the destination it may
    # overwrite.
    MovesFiles
    Recursive
    ExecutesCode
    NetworkEgress
    ElevatedPrivilege
    ModifiesEnvironment
    # Data leaves through a destination the call doesn't reveal: the
    # host chose `Legate.log`'s when building the Interpreter, and the
    # script can't tell whether it is local or remote. Unlike
    # NetworkEgress, whose destination is the call's own URL. It only
    # makes the risk visible in a report; `Authority::Log` is what
    # governs it.
    ExternalOutput
  end

  # Whether a call's effect can be undone. `Depends` means it turns on
  # arguments a static profile can't see, such as a flag, and requires
  # a `note` explaining the condition.
  enum Reversibility
    Yes
    No
    Depends
  end

  # The summary verdict, stored so a report needn't derive it from
  # the effects.
  enum Severity
    Info
    Warning
    Error
  end

  # A native function's static risk. `RiskProfile.none`, no effects,
  # is the common case. A profile with no effects must be reversible
  # and Info; anything else raises, since the missing piece is an
  # effect.
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

    # No effects: reversible and Info.
    def self.none : RiskProfile
      RiskProfile.new
    end
  end
end
