require "./authority"

module Adjutant
  # A subsystem whose calls reach outside the VM and are authorized by
  # the core `Broker`. `Legate::Broker` is the only one.
  #
  # The provider calls `Broker#authorize` itself, passing its own
  # perimeter check as a block; core never looks a provider up to
  # route a call.
  module EffectProvider
    # Prefixes a denial message: "Legate.read denied: ...".
    abstract def provider_name : String

    # The script-visible class a DENIAL reports under — the fatal,
    # unrescuable tier (`Legate::Denied`). A policy REJECTION reports
    # under `RiskFlowRejectedError` instead, which is core's own and
    # the same for every provider.
    abstract def denied_class_name : String

    # The authorities this provider grants. Two providers may grant
    # the same one, so key any registry of providers on the provider,
    # not on its authorities.
    abstract def authorities : Set(Authority)
  end
end
