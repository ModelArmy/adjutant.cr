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
  # The checks every effectful call passes through, in order:
  #
  #   1. The run's wall-clock budget, before anything else.
  #   2. The perimeter, supplied by the provider as a block, since it
  #      knows which of its predicates applies. A denial raises the
  #      unrescuable `FatalSignal(:denied)`, so a script can't swallow
  #      a denied grant.
  #   3. The risk-flow policy, through `ncc.declare_sensitivity`, which
  #      raises the rescuable RiskFlowRejectedError itself; this only
  #      records it and re-raises. The label it returns is passed back
  #      for the caller to tag the data it returns.
  #
  # Each outcome (denied, rejected, allowed) appends one AuditRecord
  # before returning or raising (LEGATE.md §8.7). Byte budgets are
  # checked by whoever moves the bytes (`Budget#record_read`), since
  # nothing is counted yet here.
  #
  # One per run, shared by every provider, since the budget, audit log
  # and open sources are per-run state.
  class Broker
    getter budget : Budget
    getter audit_log : AuditLog

    # Stream sources opened in this run and not yet closed; see
    # `open_sources.cr`.
    getter open_sources : OpenSources

    # `budget` and `audit_log` can be supplied, to inspect afterwards
    # or share across runs; each defaults to a fresh instance.
    def initialize(limits : ResourceLimits, budget : Budget? = nil, audit_log : AuditLog = AuditLog.new)
      @budget = budget || Budget.new(limits)
      @audit_log = audit_log
      # Not injectable: two Brokers sharing it could close each
      # other's handles.
      @open_sources = OpenSources.new(limits.max_open_streams)
    end

    # Runs the three checks for one call. `operation` and `subject`
    # (the verb, the path or host) are descriptive only; `provider`
    # names the error class a denial raises.
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

    # The class a policy rejection reports under, the same for every
    # provider, since the refusal is Adjutant's. A denial reports under
    # the provider's `denied_class_name`.
    REJECTED_CLASS_NAME = "RiskFlowRejectedError"

    private def deny!(provider : EffectProvider, operation : String,
                      decision : Grants::Decision) : NoReturn
      raise FatalSignal.new(:denied, "#{provider.provider_name}.#{operation} denied: #{decision.reason}")
    end
  end
end
