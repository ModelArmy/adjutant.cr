require "./grants"
require "./authorization"
require "./budget"
require "./audit_log"
require "./exceptions"
require "../risk_profile"
require "../risk_flow_label"
require "../native_call_context"

module Adjutant
  module Legate
    # Legate::Broker — LEGATE.md §8's actual enforcement authority.
    # Every effectful verb (step 5) calls exactly one of this class's
    # `authorize_*` methods at its own boundary, before doing anything
    # to the outside world. Sequences the checks this session's design
    # conversation settled on, ALWAYS in this order:
    #
    #   1. Wall-clock budget (§7/§8.4, `Budget#check_wall_clock!`) —
    #      checked FIRST and unconditionally, since a script that's
    #      overrun its run-length budget shouldn't get a fresh Grants/
    #      RiskFlowPolicy evaluation on its way to being stopped; this
    #      is a plain "is the run still allowed to continue at all,"
    #      ahead of "is THIS call allowed."
    #   2. Grants (STATIC, this broker's own `@grants`, via 4b's
    #      `check_root`/`check_host`/`check_binary`) — a structural
    #      "is this call allowed to happen at all," decided without
    #      looking at what data is flowing through it. A denial here
    #      is FATAL: `Legate::FatalSignal.new(:denied, ...)`,
    #      unrescuable by any script `rescue` (exceptions.cr) — a
    #      script must not be able to swallow a denied grant.
    #   3. RiskFlowPolicy (DYNAMIC) — reached ONLY once steps 1–2
    #      pass, via `ncc.declare_sensitivity`. This broker does not
    #      reimplement Reject/Ask handling; `declare_sensitivity`
    #      already raises the existing SCRIPT-CATCHABLE
    #      RiskFlowRejectedError (vm.cr) on its own when policy
    #      objects — this class just rescues it in Crystal terms
    #      (typed as `RuntimeError`, the SAME `Adjutant::RuntimeError`
    #      the dispatch loop's own `rescue ex : RuntimeError` clause
    #      catches — resolved via Crystal's outward namespace lookup
    #      from inside `Adjutant::Legate`, not the stdlib class of the
    #      same name) long enough to append an audit record, then
    #      re-raises it completely unchanged.
    #
    # Every one of the three outcomes (denied / rejected / allowed)
    # appends exactly one §8.7 AuditRecord before returning or
    # raising — including on the fatal path, matching §8.7's own
    # "every fatal exception is logged before unwinding begins."
    #
    # `total_read`/`total_write` budget consumption is NOT checked
    # here — the broker runs BEFORE a verb's effect, with no byte
    # count yet to test. See Budget#record_read/#record_write's own
    # comments: those are called BY a verb (step 5) after it moves
    # real bytes, independently of these authorize_* calls.
    class Broker
      getter budget : Budget
      getter audit_log : AuditLog

      # Public so a VERB (step 5) can read policy limits directly
      # (e.g. `Legate.read`'s own `limit:` kwarg has to be clamped to
      # `grants.limits.read_limit`, never allowed to exceed it) —
      # `Grants` itself is immutable config, so exposing it read-only
      # here carries no risk of a verb mutating policy out from under
      # the broker.
      getter grants : Grants

      # `budget`/`audit_log` are both injectable (a real embedder, and
      # every spec below, can supply their own to inspect afterward or
      # to share a Budget across a sequence of calls) but default to a
      # fresh instance each — the common case of "one Broker per run"
      # needs no caller-side wiring at all.
      def initialize(grants : Grants, budget : Budget? = nil, audit_log : AuditLog = AuditLog.new)
        @grants = grants
        @budget = budget || Budget.new(grants.limits)
        @audit_log = audit_log
      end

      # §4.1's `read`-grant boundary. `path` is the raw string a verb
      # already extracted from its own argument (a Legate::Path or a
      # bare String) — converting a script-level argument into that
      # raw string is the VERB's job (step 5, LEGATE.md §8's own
      # "every path argument becomes a Legate::Path at the boundary"
      # requirement), not this broker's; the broker only ever sees the
      # resolved string it needs to check.
      #
      # `allow_missing` switches to `check_root_maybe_missing` instead
      # of plain `check_root` — for a verb like `Legate.stat` where a
      # non-existent path is a documented, non-exceptional `nil`
      # result (§2.3), not a denial; see that method's own comment
      # (authorization.cr). Defaults false, matching every OTHER
      # read-grant verb, where a missing path really is just missing.
      def authorize_read(path : String, ncc : NativeCallContext, allow_missing : Bool = false) : Nil
        authorize(:read, "read", path, RiskTag::ReadsFiles, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, @grants.read_roots) : @grants.check_root(path, @grants.read_roots)
        end
      end

      # §4.3's `write`-grant boundary. Shares `check_root`'s own
      # documented gap with `authorize_delete` below: a target that
      # does not exist yet (the normal case for a fresh write) has
      # nothing for `File.realpath` to resolve, so `check_root` denies
      # it as "does not exist" rather than checking containment.
      # Resolving the PARENT directory instead for a not-yet-existing
      # write target is real, necessary work — it belongs with the
      # `write` verb itself (step 5), which is what actually knows
      # whether `path` is expected to exist yet, not this
      # general-purpose boundary method.
      def authorize_write(path : String, ncc : NativeCallContext) : Nil
        authorize(:write, "write", path, RiskTag::WritesFiles, ProvenanceKind::File, ncc) do
          @grants.check_root(path, @grants.write_roots)
        end
      end

      # §4.4's `delete`-grant boundary. Unlike `write`, a delete
      # target existing is the normal case (nothing to delete
      # otherwise), so `check_root`'s exists-only assumption is a
      # non-issue here.
      def authorize_delete(path : String, ncc : NativeCallContext) : Nil
        authorize(:delete, "delete", path, RiskTag::DeletesFiles, ProvenanceKind::File, ncc) do
          @grants.check_root(path, @grants.delete_roots)
        end
      end

      # §4.6ish's `net`-grant boundary — allowlist membership only
      # (4b's `check_host`). §8.2's SSRF/DNS-resolved-address-range
      # hardening needs the connection's actual resolved address,
      # which only exists mid-call inside a real `net` verb, so it is
      # NOT part of this boundary check — a verb calling this method
      # still has its own further check to make after DNS resolution,
      # same as `authorize_write`'s parent-directory case above.
      def authorize_net(host : String, ncc : NativeCallContext) : Nil
        authorize(:net, "net", host, RiskTag::NetworkEgress, ProvenanceKind::Host, ncc) do
          @grants.check_host(host)
        end
      end

      # §4.something's `exec`-grant boundary — binary allowlist only
      # (4b's `check_binary`). §8.3's exec sandboxing (argv/env
      # scrubbing, working directory confinement) is NOT part of this
      # boundary check, same reasoning as `authorize_net` above — it
      # needs the real subprocess call the `exec` verb is about to
      # make, not just the resolved binary path this method checks.
      #
      # Uses ProvenanceKind::File for the resolved binary path — there
      # is no dedicated "Binary" ProvenanceKind (risk_flow_label.cr
      # only defines File/Host/Env/UserInput), and a binary's absolute
      # path is, at the provenance-tracking level, still a filesystem
      # path. Worth flagging as a judgment call rather than something
      # the spec states outright.
      def authorize_exec(binary : String, ncc : NativeCallContext) : Nil
        authorize(:exec, "exec", binary, RiskTag::ExecutesCode, ProvenanceKind::File, ncc) do
          @grants.check_binary(binary)
        end
      end

      # The shared shape every authorize_* method above follows:
      # wall-clock check, then the caller-supplied Grants decision
      # (each grant category resolves its own Decision differently —
      # `check_root` vs `check_host` vs `check_binary` — hence the
      # block rather than a fixed argument), then RiskFlowPolicy, with
      # exactly one AuditRecord appended per outcome. `grant` is the
      # AuditRecord's own grant-category symbol; `verb`/`subject` are
      # both purely descriptive (verb name, the path/host/binary
      # string) and never affect the decision itself.
      private def authorize(grant : Symbol, verb : String, subject : String, tag : RiskTag,
                            provenance_kind : ProvenanceKind, ncc : NativeCallContext, & : -> Grants::Decision) : Nil
        @budget.check_wall_clock!

        decision = yield
        unless decision.allowed?
          @audit_log.append(AuditRecord.new(verb, subject, grant, :denied, FATAL_CLASS_NAME))
          deny!(verb, decision)
        end

        begin
          ncc.declare_sensitivity(tag, provenance_kind, subject)
        rescue ex : RuntimeError
          @audit_log.append(AuditRecord.new(verb, subject, grant, :rejected, REJECTED_CLASS_NAME))
          raise ex
        end

        @audit_log.append(AuditRecord.new(verb, subject, grant, :allowed))
      end

      # The script-visible class names a :denied/:rejected AuditRecord
      # reports under. `FATAL_CLASS_NAME` is fixed at "Legate::Denied"
      # here — the only fatal kind this broker itself ever raises is
      # `:denied` (never `:exhausted`, that's Budget's own concern via
      # a DIFFERENT raise path that doesn't go through this method at
      # all; never `:aborted`, which is script-initiated per §9.2 and
      # nothing this broker does).
      FATAL_CLASS_NAME    = "Legate::Denied"
      REJECTED_CLASS_NAME = "RiskFlowRejectedError"

      private def deny!(verb : String, decision : Grants::Decision) : NoReturn
        raise FatalSignal.new(:denied, "Legate.#{verb} denied: #{decision.reason}")
      end
    end
  end
end
