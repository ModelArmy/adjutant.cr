module Adjutant
  # A permission a call must hold to reach outside the VM, and the
  # key a `RiskFlowRule` matches on. `Effect` is the separate
  # vocabulary for what a call does; see DEVELOPMENT.md, "Side-effect
  # risk".
  #
  # An authority is a grant (checked by `Broker#authorize`), a sink
  # (declared in `NativeCallable#authorities`), or both. `Ambient` is
  # only a grant, so no `RiskFlowRule` names it; `Log` is only a sink.
  enum Authority
    Read
    Write
    Delete
    Net
    Ambient
    Log
  end
end
