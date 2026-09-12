module Adjutant
  # A kind of permission a call must hold to reach outside the VM.
  #
  # Deliberately NOT the same vocabulary as Effect. The two answer
  # different questions and their memberships differ:
  #
  #   Authority — what a call is PERMITTED to do. Enforced. Granted by
  #     whatever embeds Adjutant, checked before the call runs, and the
  #     key a RiskFlowRule matches on.
  #   Effect — what a call DOES to the world. Reported. The vocabulary
  #     of the static risk manifest a human reads before deciding to
  #     run a script at all.
  #
  # A move is the clearest case: it needs Delete and Write authority,
  # but destroys nothing — the entry ends up somewhere else. Reporting
  # it as a deletion would be false; refusing it Delete authority would
  # be wrong. One enum could not say both.
  #
  # These were a single enum until 2026-09-01. See
  # research/IFC_DESIGN.md's "Reusing the existing risk vocabulary"
  # section for the original decision and why it was reversed.
  #
  # Ambient is a SOURCE, not a sink: `env` reading an allowlisted name
  # is where sensitivity gets attached, and the authority a value
  # eventually reaches is Net, Write, or Log. So Ambient will
  # legitimately never appear in a RiskFlowRule row. That is a
  # property of what the authority means, not a gap in the rule
  # table.
  #
  # `Exec` removed 2026-09-05: `Legate.run` was never built, and the
  # scaffolding around it (this member, the binary allowlist, the
  # broker boundary) was unused. See SCOPE.md and LEGATE.md §4.6.
  #
  # `Log` added 2026-09-10 — `Legate.log`'s own sink. Not wired
  # through `Broker#authorize` the way Read/Write/Delete/Net are
  # (§4.7's ambient verbs bypass that whole sequence — broker.cr's
  # own comment); reached only through `VM#check_risk_flow`'s
  # labeled-argument check instead, via `NativeCallable#authorities`
  # on `Legate.log`'s own definition. See SCOPE.md's entry on why
  # `Legate.log` needed a real sink authority, not just a static
  # Effect, and on the much larger unrelated finding that surfaced
  # alongside it: no read/write/delete/net verb declares
  # `authorities:` either, so none of them are actually protected by
  # this mechanism today.
  enum Authority
    Read
    Write
    Delete
    Net
    Ambient
    Log
  end
end
