require "./authority"
require "./audit_log"
require "./budget"
require "./effect_provider"
require "./fatal_signal"
require "./grants"
require "./open_sources"
require "./native_call_context"
require "./risk_flow_label"

module Adjutant
  # The enforcement sequence every effectful call goes through, in
  # this order, always:
  #
  #   1. Wall-clock budget — checked FIRST and unconditionally, since
  #      a run that has overrun its length shouldn't get a fresh
  #      perimeter and policy evaluation on its way to being stopped.
  #      This is "is the run still allowed to continue at all," ahead
  #      of "is THIS call allowed."
  #   2. The perimeter (STATIC) — a structural "is this call allowed
  #      to happen at all," decided without looking at what data is
  #      flowing through it. Supplied by the calling provider as a
  #      block, because each category resolves differently (a path
  #      root vs a net rule vs a binary allowlist) and the provider
  #      knows which of its own predicates applies. A denial here is
  #      FATAL: an unrescuable `FatalSignal(:denied)`, because a
  #      script must not be able to swallow a denied grant.
  #   3. RiskFlowPolicy (DYNAMIC) — reached ONLY once 1–2 pass, via
  #      `ncc.declare_sensitivity`. This class does not reimplement
  #      Reject/Ask handling; `declare_sensitivity` already raises the
  #      SCRIPT-CATCHABLE RiskFlowRejectedError on its own when policy
  #      objects, and this just rescues it long enough to append an
  #      audit record, then re-raises it completely unchanged. Its
  #      RETURN VALUE (the `RiskFlowLabel?` policy resolved for this
  #      subject) is threaded back out so a caller can tag the data it
  #      is about to return — gating the READ correctly is not the
  #      same as tainting the DATA correctly.
  #
  # Every one of the three outcomes (denied / rejected / allowed)
  # appends exactly one AuditRecord before returning or raising —
  # including on the fatal path, matching LEGATE.md §8.7's "every
  # fatal exception is logged before unwinding begins."
  #
  # `total_read`/`total_write` consumption is NOT checked here: this
  # runs BEFORE an effect, with no byte count yet to test. See
  # `Budget#record_read`/`#record_write`, called by whoever actually
  # moves the bytes.
  #
  # ONE PER RUN, SHARED BY EVERY PROVIDER. This was `Legate::Broker`
  # until 2026-09-01, and promoting it mattered for more than
  # layering: `Budget`, `AuditLog` and `OpenSources` are per-RUN
  # state, so a second provider with a broker of its own would have
  # split the run's `total_read` across two budgets that each enforced
  # half of it, and fragmented the audit log the same way. A provider
  # therefore holds a reference to the run's broker rather than being
  # or owning one.
  class Broker
    getter budget : Budget
    getter audit_log : AuditLog

    # Every stream-backing source opened during this run that has not
    # yet closed itself — see `open_sources.cr` for why a registry is
    # needed at all, and why closing on walk-halt is not an acceptable
    # substitute.
    #
    # Lives here rather than on the Interpreter for the same reason
    # `budget` and `audit_log` do: it is per-RUN state accumulated by
    # calls, and this is the one instance every provider already holds.
    # A caller reaching a fresh registry through some other path would
    # be a second source of truth for what is open.
    getter open_sources : OpenSources

    # `budget`/`audit_log` are both injectable (a real embedder, and
    # the specs, can supply their own to inspect afterward or to share
    # across a sequence of calls) but default to a fresh instance
    # each — the common case of "one Broker per run" needs no
    # caller-side wiring at all.
    def initialize(limits : ResourceLimits, budget : Budget? = nil, audit_log : AuditLog = AuditLog.new)
      @budget = budget || Budget.new(limits)
      @audit_log = audit_log
      # Not injectable, unlike `budget`/`audit_log`. Those are
      # inspectable RESULTS an embedder may legitimately want to
      # supply; this is live resource ownership, and two Brokers
      # sharing one registry would mean either could close the other's
      # open handles.
      @open_sources = OpenSources.new(limits.max_open_streams)
    end

    # The shared shape every provider's own authorize_* wrapper
    # follows. `operation`/`subject` are purely descriptive (the verb
    # name, the path/host/binary string) and never affect the decision
    # itself; `provider` supplies the naming a denial reports under.
    def authorize(provider : EffectProvider, authority : Authority, operation : String,
                  subject : String, provenance_kind : ProvenanceKind,
                  ncc : NativeCallContext, & : -> Grants::Decision) : RiskFlowLabel?
      @budget.check_wall_clock!

      decision = yield
      unless decision.allowed?
        @audit_log.append(AuditRecord.new(operation, subject, authority, :denied, provider.denied_class_name))
        deny!(provider, operation, decision)
      end

      label = begin
        ncc.declare_sensitivity(authority, provenance_kind, subject)
      rescue ex : RuntimeError
        @audit_log.append(AuditRecord.new(operation, subject, authority, :rejected, REJECTED_CLASS_NAME))
        raise ex
      end

      @audit_log.append(AuditRecord.new(operation, subject, authority, :allowed))
      label
    end

    # The script-visible class a :rejected AuditRecord reports under.
    # Core's own, and the same for every provider — a policy rejection
    # is Adjutant's refusal, not the provider's. The :denied
    # counterpart is the provider's (`EffectProvider#denied_class_name`)
    # because the fatal tier is where a provider names its own errors.
    REJECTED_CLASS_NAME = "RiskFlowRejectedError"

    private def deny!(provider : EffectProvider, operation : String,
                      decision : Grants::Decision) : NoReturn
      raise FatalSignal.new(:denied, "#{provider.provider_name}.#{operation} denied: #{decision.reason}")
    end
  end
end
