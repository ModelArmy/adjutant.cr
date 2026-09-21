require "./authority"

module Adjutant
  # A subsystem that reaches outside the VM and therefore needs its
  # effects authorized — Legate today, and the shape anything else
  # would take.
  #
  # Exists so the core `Broker` can sequence an authorization without
  # knowing whose it is. The three things it asks for are all things
  # only the provider knows: what to call itself in a denial message,
  # which script-visible class a denial reports under, and which
  # authorities it claims.
  #
  # NOT a dispatch mechanism, deliberately. Core does not look a
  # provider up to decide who handles a call — the provider calls the
  # broker itself and supplies the perimeter decision through a block,
  # which is more precise than a lookup could be, since the provider
  # knows which of its own predicates applies (a path root vs a net
  # rule vs a binary allowlist) and core does not.
  #
  # `authorities` is therefore unused by the sequence today. It is
  # declared because two things will need to iterate providers rather
  # than dispatch to them: the unified config (each provider parses
  # its own section) and LEGATE.md §10.1's grant inference, which
  # currently walks the call graph for `Legate.*` names and must key
  # on something registered instead — otherwise a second provider gets
  # enforcement but no static manifest, exactly the asymmetry the
  # manifest exists to prevent. See SCOPE.md.
  #
  # Note what `authorities` is NOT: a routing key. Two providers may
  # both claim `Read` against different perimeters, so a
  # `Hash(Authority, Provider)` would have room for only one of them.
  # Any future registry keys on the PROVIDER, with its authorities as
  # data.
  #
  # One implementer today (`Legate::Broker`). Named now rather than
  # later so a second subsystem is an addition rather than a
  # re-architecture — the cost is an abstract type with a single
  # conformer, which is the accepted price recorded in SCOPE.md.
  module EffectProvider
    # Prefixes a denial message: "Legate.read denied: ...".
    abstract def provider_name : String

    # The script-visible class a DENIAL reports under — the fatal,
    # unrescuable tier (`Legate::Denied`). A policy REJECTION reports
    # under `RiskFlowRejectedError` instead, which is core's own and
    # the same for every provider.
    abstract def denied_class_name : String

    # Which authorities this provider claims. See the note above on
    # why this is data rather than a routing key.
    abstract def authorities : Set(Authority)
  end
end
