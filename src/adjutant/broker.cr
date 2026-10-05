require "./authority"
require "./audit_log"
require "./budget"
require "./effect_provider"
require "./fatal_signal"
require "./grants"
require "./open_sources"
require "./real_path"
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
  #   3. The risk-flow policy, through `ncc.check_flow_at` for the data
  #      reaching the subject, then `ncc.declare_sensitivity` for the
  #      subject's own. Each raises the rescuable RiskFlowRejectedError
  #      itself; this only records it and re-raises. The label
  #      `declare_sensitivity` returns is passed back for the caller to
  #      tag the data it returns.
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

    # Runs the three checks for one call. `operation` names the verb;
    # `subject` (the path, or `scheme://host:port`) is where the
    # risk-flow policy sees the data going, and a File subject is
    # judged and audited as its `RealPath.of`; `provider` names the
    # error class a denial raises. `flowing` holds the labels of the
    # data sent to `subject`, when that isn't every argument, such as
    # a redirect hop's surviving headers.
    def authorize(provider : EffectProvider, authority : Authority, operation : String,
                  subject : String, provenance_kind : ProvenanceKind,
                  ncc : NativeCallContext, flowing : Array(RiskFlowLabel)? = nil,
                  & : -> Grants::Decision) : RiskFlowLabel?
      @budget.check_wall_clock!
      subject = judged_subject(subject, provenance_kind)

      decision = yield
      unless decision.allowed?
        @audit_log.append(AuditRecord.new(operation, subject, authority, :denied, provider.denied_class_name))
        deny!(provider, operation, decision)
      end

      label = begin
        ncc.check_flow_at(authority, subject, flowing)
        ncc.declare_sensitivity(authority, provenance_kind, subject)
      rescue ex : RuntimeError
        @audit_log.append(AuditRecord.new(operation, subject, authority, :rejected, REJECTED_CLASS_NAME))
        raise ex
      end

      @audit_log.append(AuditRecord.new(operation, subject, authority, :allowed))
      label
    end

    # The sensitivity check alone, for a subject inside one `authorize`
    # already allowed, such as each file a glob matched: labels it, and
    # asks or rejects as the policy says. A rejection is recorded in
    # the audit log; an allowed subject adds no record, so a large
    # listing still makes one per call.
    def label_within(authority : Authority, operation : String, subject : String,
                     provenance_kind : ProvenanceKind, ncc : NativeCallContext) : RiskFlowLabel?
      subject = judged_subject(subject, provenance_kind)
      ncc.declare_sensitivity(authority, provenance_kind, subject)
    rescue ex : RuntimeError
      @audit_log.append(AuditRecord.new(operation, subject, authority, :rejected, REJECTED_CLASS_NAME))
      raise ex
    end

    # The class a policy rejection reports under, the same for every
    # provider, since the refusal is Adjutant's. A denial reports under
    # the provider's `denied_class_name`.
    REJECTED_CLASS_NAME = "RiskFlowRejectedError"

    # A File subject as the policy matches it, `RealPath.of`, so a
    # respelled or linked path meets the patterns of the file it
    # reaches. A symlink is judged as its target even by a verb that
    # acts on the link itself, which errs towards the stricter answer.
    # A path that doesn't resolve keeps its spelling; the perimeter
    # denies it first. Any other kind is returned as given.
    private def judged_subject(subject : String, provenance_kind : ProvenanceKind) : String
      return subject unless provenance_kind.file?
      RealPath.of(subject) || subject
    end

    private def deny!(provider : EffectProvider, operation : String,
                      decision : Grants::Decision) : NoReturn
      raise FatalSignal.new(:denied, "#{provider.provider_name}.#{operation} denied: #{decision.reason}")
    end
  end
end
