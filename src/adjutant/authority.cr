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
  # eventually reaches is Net (or Write, or Exec). So Ambient will
  # legitimately never appear in a RiskFlowRule row. That is a property
  # of what the authority means, not a gap in the rule table.
  enum Authority
    Read
    Write
    Delete
    Net
    Exec
    Ambient
  end
end
