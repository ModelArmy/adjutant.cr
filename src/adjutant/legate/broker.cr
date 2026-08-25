require "./grants"
require "./authorization"
require "./exceptions"
require "../risk_profile"
require "../risk_flow_label"
require "../native_call_context"

module Adjutant
  module Legate
    # Legate::Broker — LEGATE.md §8's actual enforcement authority.
    # Every effectful verb (step 5) calls exactly one of this class's
    # `authorize_*` methods at its own boundary, before doing anything
    # to the outside world. Sequences the two checks this session's
    # design conversation settled on, ALWAYS in this order:
    #
    #   1. Grants (STATIC, this broker's own `@grants`, via 4b's
    #      `check_root`/`check_host`/`check_binary`) — a structural
    #      "is this call allowed to happen at all," decided without
    #      looking at what data is flowing through it. A denial here
    #      is FATAL: `Legate::FatalSignal.new(:denied, ...)`,
    #      unrescuable by any script `rescue` (exceptions.cr) — a
    #      script must not be able to swallow a denied grant.
    #   2. RiskFlowPolicy (DYNAMIC) — reached ONLY once step 1 passes,
    #      via `ncc.declare_sensitivity`. This broker does not
    #      reimplement Reject/Ask handling; `declare_sensitivity`
    #      already raises the existing SCRIPT-CATCHABLE
    #      RiskFlowRejectedError (vm.cr) on its own when policy
    #      objects. Grants is the ceiling; RiskFlowPolicy is the
    #      judgment underneath it — see this session's own grants-vs-
    #      RiskFlowPolicy conversation for the fuller reasoning.
    #
    # `@grants` is fixed at construction — one Broker per run, built
    # from whatever Grants the embedder supplied, matching §7's "fixed
    # before execution, never escalatable."
    #
    # Budgets (per-run cumulative memory/wall-clock/total-read/write
    # exhaustion, §7's other half) are NOT this class's job yet —
    # deliberately deferred to step 4d, which adds the counters and
    # wraps these same authorize_* methods rather than replacing them.
    class Broker
      def initialize(@grants : Grants)
      end

      # §4.1's `read`-grant boundary. `path` is the raw string a verb
      # already extracted from its own argument (a Legate::Path or a
      # bare String) — converting a script-level argument into that
      # raw string is the VERB's job (step 5, LEGATE.md §8's own
      # "every path argument becomes a Legate::Path at the boundary"
      # requirement), not this broker's; the broker only ever sees the
      # resolved string it needs to check.
      def authorize_read(path : String, ncc : NativeCallContext) : Nil
        authorize(:read, "read", path, @grants.read_roots, RiskTag::ReadsFiles, ncc)
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
        authorize(:write, "write", path, @grants.write_roots, RiskTag::WritesFiles, ncc)
      end

      # §4.4's `delete`-grant boundary. Unlike `write`, a delete
      # target existing is the normal case (nothing to delete
      # otherwise), so `check_root`'s exists-only assumption is a
      # non-issue here.
      def authorize_delete(path : String, ncc : NativeCallContext) : Nil
        authorize(:delete, "delete", path, @grants.delete_roots, RiskTag::DeletesFiles, ncc)
      end

      # §4.6ish's `net`-grant boundary — allowlist membership only
      # (4b's `check_host`). §8.2's SSRF/DNS-resolved-address-range
      # hardening needs the connection's actual resolved address,
      # which only exists mid-call inside a real `net` verb, so it is
      # NOT part of this boundary check — a verb calling this method
      # still has its own further check to make after DNS resolution,
      # same as `authorize_write`'s parent-directory case above.
      def authorize_net(host : String, ncc : NativeCallContext) : Nil
        decision = @grants.check_host(host)
        deny!("net", decision) unless decision.allowed?
        ncc.declare_sensitivity(RiskTag::NetworkEgress, ProvenanceKind::Host, host)
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
        decision = @grants.check_binary(binary)
        deny!("exec", decision) unless decision.allowed?
        ncc.declare_sensitivity(RiskTag::ExecutesCode, ProvenanceKind::File, binary)
      end

      private def authorize(kind : Symbol, verb : String, path : String, roots : Array(String),
                            tag : RiskTag, ncc : NativeCallContext) : Nil
        decision = @grants.check_root(path, roots)
        deny!(verb, decision) unless decision.allowed?
        ncc.declare_sensitivity(tag, ProvenanceKind::File, path)
      end

      # `kind` on FatalSignal is always `:denied` here — a static
      # Grants refusal, never `:exhausted` (that's step 4d's budgets)
      # or `:aborted` (script-initiated, LEGATE.md §9.2 — nothing this
      # broker does).
      private def deny!(verb : String, decision : Grants::Decision) : NoReturn
        raise FatalSignal.new(:denied, "Legate.#{verb} denied: #{decision.reason}")
      end
    end
  end
end
