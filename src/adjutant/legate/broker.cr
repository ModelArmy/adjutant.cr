require "./grants"
require "./authorization"
require "./budget"
require "./exceptions"
require "../broker"
require "../effect_provider"
require "../risk_profile"
require "../risk_flow_label"
require "../native_call_context"

module Adjutant
  module Legate
    # Legate's side of LEGATE.md §8 — the `EffectProvider` that owns
    # Legate's perimeter and names Legate's errors.
    #
    # The SEQUENCE itself (wall-clock, then the perimeter decision,
    # then RiskFlowPolicy, with exactly one AuditRecord per outcome)
    # moved to `Adjutant::Broker` on 2026-09-01. This class holds a
    # reference to the run's shared instance rather than being one:
    # `Budget`, `AuditLog` and `OpenSources` are per-RUN state, and a
    # second provider owning a broker of its own would split the run's
    # budget in half and fragment its audit log. See
    # `src/adjutant/broker.cr`.
    #
    # What stays here is what only Legate knows: which roots, rules
    # and binaries make up its perimeter (`@grants`), that a denial
    # reports as `Legate::Denied`, and the five verb-facing
    # `authorize_*` wrappers below — each of which knows about
    # `allow_missing`, about which §4 verb it serves, and about what a
    # missing path means for that verb. Fourteen verbs talking to a
    # generic `authorize` directly would have to re-derive all of
    # that.
    #
    # Every effectful verb calls exactly one `authorize_*` method at
    # its own boundary, before doing anything to the outside world.
    #
    class Broker
      include ::Adjutant::EffectProvider

      # The run's shared authorization sequence. Delegated to rather
      # than inherited from: a provider is not a broker, it uses one.
      getter core : ::Adjutant::Broker

      delegate budget, audit_log, open_sources, to: @core

      def provider_name : String
        "Legate"
      end

      # LEGATE.md §9.2's fatal tier. The only fatal kind this provider
      # itself ever raises through the broker is `:denied` — never
      # `:exhausted`, which is Budget's own concern via a different
      # raise path, and never `:aborted`, which is script-initiated.
      def denied_class_name : String
        "Legate::Denied"
      end

      # The five grant categories §7 defines. `Ambient` is absent
      # deliberately: it is a SOURCE of sensitivity rather than a
      # sink, so nothing authorizes against it.
      def authorities : Set(Authority)
        AUTHORITIES
      end

      AUTHORITIES = Set{Authority::Read, Authority::Write, Authority::Delete,
                        Authority::Net, Authority::Exec}

      # Public so a VERB can read policy limits directly (e.g.
      # `Legate.read`'s own `limit:` kwarg has to be clamped to
      # `grants.limits.read_limit`, never allowed to exceed it) —
      # `Grants` itself is immutable config, so exposing it read-only
      # here carries no risk of a verb mutating policy out from under
      # the broker.
      getter grants : Grants

      # `core` is the run's shared broker. Defaulted so the common
      # case ("one run, one provider") needs no caller-side wiring,
      # and so every existing `Legate::Broker.new(grants)` call site
      # keeps working — but an Interpreter with more than one provider
      # passes the SAME instance to each, which is the entire point of
      # the sequence being shared.
      #
      # `budget`/`audit_log` remain injectable for specs and embedders
      # that want to inspect them afterward; they are forwarded to the
      # broker this constructs, and ignored when `core` is supplied
      # (the shared broker already has its own).
      def initialize(grants : Grants, core : ::Adjutant::Broker? = nil,
                     budget : Budget? = nil, audit_log : AuditLog = AuditLog.new)
        @grants = grants
        @core = core || ::Adjutant::Broker.new(grants.limits, budget, audit_log)
      end

      # Refuses to let the run open one more stream once
      # `max_open_streams` are already open.
      #
      # SEPARATE FROM `register_source`, and called BEFORE the
      # resource is acquired — not folded into registration for the
      # one reason that matters: a verb opens its `File` (or, later,
      # its connection) and only then has something to register, so a
      # cap enforced at registration time would refuse a handle that
      # is already open and that nothing would then be holding to
      # close. Checking first means the refusal happens while there is
      # still nothing to leak.
      #
      # NOT an `authorize_*` method, and deliberately not shaped like
      # one: there is no grant to consult, no sensitivity to declare
      # and no audit entry to write — opening a stream was already
      # authorized by the `authorize_read` (or, later,
      # `authorize_net`) call the verb made moments earlier. This is
      # resource accounting for a call that has ALREADY been allowed,
      # which is why it sits alongside `budget` rather than inside the
      # authorization sequence.
      #
      # The verb passes its own `TooMany` class in for the same reason
      # every other Legate verb does: nested Legate error classes
      # resolve only via real ConstPath lookup, so they cannot be
      # fetched by name from here.
      #
      # The message names the cap and the remedy. A script hitting
      # this is almost always opening streams in a loop without
      # consuming them, and the fix is to finish walking one before
      # opening the next — §9.1's "the message MUST hint at" column,
      # applied to a limit §9 does not yet list.
      def check_stream_capacity!(ncc : NativeCallContext, too_many : RubyClass) : Nil
        return unless open_sources.at_capacity?
        ncc.raise_error_class(
          "#{open_sources.max_open} streams are already open — finish walking one before opening another, " \
          "or raise max_open_streams in the policy's limits",
          too_many,
        )
      end

      # Takes ownership of one stream-backing source for the rest of
      # the run. Pair with `check_stream_capacity!`, called before the
      # underlying handle was opened.
      def register_source(source : Closable) : Nil
        open_sources.register(source)
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
      def authorize_read(path : String, ncc : NativeCallContext, allow_missing : Bool = false) : RiskFlowLabel?
        @core.authorize(self, Authority::Read, "read", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, @grants.read_roots) : @grants.check_root(path, @grants.read_roots)
        end
      end

      # §4.3's `write`-grant boundary. Shares `check_root`'s own
      # documented gap with `authorize_delete` below: a target that
      # does not exist yet (the normal case for a fresh write) has
      # nothing for `File.realpath` to resolve, so `check_root` denies
      # it as "does not exist" rather than checking containment.
      # `allow_missing` (added 2026-08-27, alongside `write.cr` itself
      # — the "belongs with the write verb, which is what actually
      # knows whether `path` is expected to exist yet" from this
      # method's own comment, now that such a verb exists) mirrors
      # `authorize_read`'s identical param exactly: `write.cr` passes
      # `true` (the normal, expected case), `append.cr`/`mkdir.cr`
      # will too; a hypothetical future caller that genuinely expects
      # the target to already exist can still get the stricter
      # existing-only check by leaving the default.
      def authorize_write(path : String, ncc : NativeCallContext, allow_missing : Bool = false) : RiskFlowLabel?
        @core.authorize(self, Authority::Write, "write", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, @grants.write_roots) : @grants.check_root(path, @grants.write_roots)
        end
      end

      # §4.4's `delete`-grant boundary.
      #
      # `allow_missing` is not optional decoration. §4.4 states that
      # `Legate.rm` on a MISSING path returns `0` — a documented,
      # non-exceptional result, part of §2.3's "nil/0 for a
      # non-existent path" family. Strict `check_root` denies any path
      # it cannot resolve, and a denial here is FATAL and unrescuable
      # (see `deny!` below), so wiring this method to the strict check
      # would make `Legate.rm("gone.txt")` kill the run even for a
      # path INSIDE a granted delete root. The grant is not the
      # problem in that case; the path simply isn't there.
      #
      # `allow_missing` therefore mirrors `authorize_read`/
      # `authorize_write`'s identical parameter exactly, and for the
      # same underlying reason: whether a not-yet/no-longer-existing
      # target is normal or exceptional is the VERB's knowledge, not
      # the broker's. `rm.cr` passes `true` and then decides for
      # itself (missing → `0`); `mv.cr` passes `true` for its source
      # and then decides differently (missing → a recoverable
      # `Legate::NotFound`, which is what §4.4's own Raises line
      # names). The default stays `false`, so any future caller that
      # genuinely requires the target to already exist still gets the
      # stricter check by saying nothing.
      def authorize_delete(path : String, ncc : NativeCallContext, allow_missing : Bool = false) : RiskFlowLabel?
        @core.authorize(self, Authority::Delete, "delete", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, @grants.delete_roots) : @grants.check_root(path, @grants.delete_roots)
        end
      end

      # §4.5's `net`-grant boundary — the STATIC half only (4b's
      # `check_net`). Takes all four of scheme/host/port/method rather
      # than a bare hostname, because a NetRule authorizes a SERVICE,
      # not a machine; see net_rule.cr's own top comment.
      #
      # §8.2's SSRF/DNS-resolved-address-range hardening needs the
      # connection's actual resolved addresses, which only exist
      # mid-call inside a real `net` verb, so it is NOT part of this
      # boundary check — a verb calling this method still has its own
      # further check to make after DNS resolution, same as
      # `authorize_write`'s parent-directory case above.
      #
      # `subject` for the audit record and for sensitivity resolution
      # is the origin form `scheme://host:port`, not the bare host.
      # That is a deliberate change of shape: a RiskFlowPolicy
      # sensitivity pattern for a network origin should be able to
      # distinguish `https://api.example.com:443` from the same name
      # on a different port, for exactly the reason the rules
      # themselves do. It does mean a pattern written against a bare
      # hostname no longer matches — worth knowing, though nothing
      # ships against the old shape yet, since no verb existed to use
      # it.
      # Whether the rule that authorized this connection opted into
      # loopback and private address space. `Legate.fetch` asks after
      # a successful `authorize_net`, to decide how strictly to vet
      # the addresses the hostname resolves to. Not part of the
      # authorization result itself because it is not an
      # allowed/denied question — the grant has already been settled
      # by the time it matters.
      def net_allows_local?(scheme : String, host : String, port : Int32, method : String) : Bool
        @grants.net_allows_local?(scheme, host, port, method)
      end

      def authorize_net(scheme : String, host : String, port : Int32, method : String,
                        ncc : NativeCallContext) : RiskFlowLabel?
        subject = "#{scheme}://#{host}:#{port}"
        @core.authorize(self, Authority::Net, "net", subject, ProvenanceKind::Host, ncc) do
          @grants.check_net(scheme, host, port, method)
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
      def authorize_exec(binary : String, ncc : NativeCallContext) : RiskFlowLabel?
        @core.authorize(self, Authority::Exec, "exec", binary, ProvenanceKind::File, ncc) do
          @grants.check_binary(binary)
        end
      end
    end
  end
end
