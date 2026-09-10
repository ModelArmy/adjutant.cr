require "log"
require "file_utils"
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
    # reports as `Legate::Denied`, the four verb-facing `authorize_*`
    # wrappers below — each of which knows about `allow_missing`,
    # about which §4 verb it serves, and about what a missing path
    # means for that verb — and two more Legate-only concerns that
    # earned a slot here rather than on core `Adjutant::Broker`
    # (`budget`/`audit_log`/`open_sources`'s own home): `log` (§4.7,
    # `Legate.log`'s destination) and the scratch directory (§4.7,
    # `Legate.scratch`'s backing store). Both stayed LOCAL rather than
    # being promoted to core the way `AuditLog`/`Budget` were on
    # 2026-09-01 — that promotion was driven by a real second
    # consumer (a hypothetical second EffectProvider would otherwise
    # split a run's budget and fragment its audit log); no second
    # provider exists today and only `Legate.log`/`Legate.scratch`
    # need either of these, so promoting them ahead of that need would
    # be generalising on the strength of an argument rather than
    # evidence — the exact thing this file's own history (see
    # `AuditLog`'s comment) already argues against doing. Revisit if a
    # second provider ever needs either.
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

      # The four grant categories §7 defines. `Ambient` is absent
      # deliberately: it is a SOURCE of sensitivity rather than a
      # sink, so nothing authorizes against it.
      def authorities : Set(Authority)
        AUTHORITIES
      end

      AUTHORITIES = Set{Authority::Read, Authority::Write, Authority::Delete, Authority::Net}

      # Public so a VERB can read policy limits directly (e.g.
      # `Legate.read`'s own `limit:` kwarg has to be clamped to
      # `grants.limits.read_limit`, never allowed to exceed it) —
      # `Grants` itself is immutable config, so exposing it read-only
      # here carries no risk of a verb mutating policy out from under
      # the broker.
      getter grants : Grants

      # `Legate.log`'s destination (§4.7). An embedder supplies its
      # own `::Log.for("...")` — a source it chose, in ITS OWN
      # dotted-name space — so several Adjutant embeddings in the
      # same process can route to different sources/backends the way
      # any other Crystal subsystem's logging would; defaults to
      # `DEFAULT_LOG` (below) when the embedder never configures one.
      #
      # CORRECTED 2026-09-10, found via a real `ops test` run
      # printing log lines this comment used to claim couldn't
      # happen: Crystal's own stdlib default is NOT silence.
      # "By default entries from all sources with Info and above
      # severity will be logged to STDOUT using the Log::IOBackend"
      # (Crystal's own `Log` docs, unchanged from 0.35.1 through at
      # least 1.19) — true for EVERY source bound to the global
      # default builder (`Log.builder`), including a plain
      # `::Log.for("adjutant.legate")`, unless something ELSEWHERE in
      # the process has already called `Log.setup` to override it.
      # `Legate.log` emits at `.info`, so this was never a no-op —
      # every call printed to STDOUT in any process that never
      # touched `Log.setup`, which describes most embedders and
      # every one of this repo's own script-tests
      # (`spec/scripts/legate/ambient_basics/`).
      #
      # `DEFAULT_LOG` fixes this by construction rather than by
      # convention: bound to a PRIVATE `Log::Builder` with NO
      # bindings at all, not `Log.builder` (Crystal's shared global
      # one), so there is genuinely nothing for an unconfigured
      # `Legate.log` call to reach — silence that holds regardless of
      # what any OTHER, unrelated part of the same process has done
      # with `Log.setup` for ITS OWN purposes, which the old
      # global-builder-based default was never actually independent
      # of.
      getter log : ::Log

      # See `getter log` above for why this exists and is NOT just
      # `::Log.for("adjutant.legate")`. A module-level constant, not
      # rebuilt per `Broker.new` call, since an empty `Log::Builder`
      # has no per-instance state worth re-creating.
      DEFAULT_LOG_BUILDER = ::Log::Builder.new
      DEFAULT_LOG         = DEFAULT_LOG_BUILDER.for("adjutant.legate")

      # `Legate.scratch`'s backing directory (§4.7) — nil until the
      # first `Legate.scratch` call THIS run, created lazily rather
      # than up front so a script that never calls it never touches
      # disk. "This run" here means one `Interpreter#eval` call, same
      # as `OpenSources` (see that class's own "SCOPE IS THE RUN, NOT
      # THE PROCESS" comment) — `Interpreter#eval`'s `ensure` block
      # calls `cleanup_scratch!` alongside `open_sources.close_all`,
      # and `scratch_dir` below is what (re-)creates it lazily on the
      # next run's first use. Deliberately NOT scoped to the whole
      # Interpreter/session: an Interpreter is long-lived and may run
      # many `eval` calls, and nothing here ever tears it down except
      # this same per-eval cleanup — durable, cross-eval working
      # space is what a real `write:` grant is for; `scratch` is
      # framed by §4.7 as incidental working space for the run at
      # hand, not the agent's persistent workspace, and giving it an
      # unbounded lifetime with no corresponding teardown hook would
      # leak a directory per Interpreter in a long-running embedder
      # process. Worth revisiting if a real use wants otherwise — see
      # SCOPE.md.
      @scratch_dir : String? = nil

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
                     budget : Budget? = nil, audit_log : AuditLog = AuditLog.new,
                     @log : ::Log = DEFAULT_LOG)
        @grants = grants
        @core = core || ::Adjutant::Broker.new(grants.limits, budget, audit_log)
      end

      # Get-or-create. `File.tempname` returns a unique path WITHOUT
      # creating anything (Crystal stdlib, `file/tempfile.cr`) —
      # `FileUtils.mkdir_p` is what actually makes it a real,
      # existing directory; both are already used elsewhere in this
      # codebase (mkdir.cr, write.cr, ...), just not yet in this
      # exact combination, so flag this specific pairing as the
      # first thing to check if `ops build` disagrees.
      def scratch_dir : String
        @scratch_dir ||= begin
          dir = File.tempname("adjutant-legate-scratch", nil)
          FileUtils.mkdir_p(dir)
          dir
        end
      end

      # Removes the scratch directory if this run ever created one,
      # and forgets it either way, so the NEXT run's first
      # `Legate.scratch` call starts fresh rather than reusing (or
      # trying to re-delete) a directory that belonged to whichever
      # run just ended. Returns the exception rather than raising —
      # same reasoning as `OpenSources#close_all`, which this is
      # meant to run alongside: this typically runs from an `ensure`,
      # often while a real script exception is already unwinding, and
      # a cleanup failure must not replace it.
      def cleanup_scratch! : Exception?
        return unless dir = @scratch_dir
        FileUtils.rm_rf(dir)
        nil
      rescue ex
        ex
      ensure
        @scratch_dir = nil
      end

      # The roots an `authorize_*` check actually authorizes against:
      # `@grants`' own configured list, PLUS the scratch directory if
      # this run has created one. Deliberately NOT implemented by
      # mutating `@grants.read_roots`/etc — LEGATE.md §7 is explicit
      # that "grants cannot be acquired, escalated or delegated at
      # runtime," and adding a root mid-run, however narrow the
      # reason, is exactly that. This sidesteps the conflict instead
      # of relaxing it: `@grants` itself never changes, and scratch
      # access was never an escalation to begin with — "scratch is
      # always writable" is true from the first line of every run
      # (§4.7's own "granted by default"), the same as any other
      # ambient default; only the PATH it resolves to is generated
      # lazily. The broker (enforcement) folding that permanent
      # allowance in at check time, rather than `Grants` (config)
      # growing to include it, keeps `Grants` a genuinely immutable,
      # embedder-authored value object throughout the run.
      private def ambient_roots(configured : Array(String)) : Array(String)
        return configured unless dir = @scratch_dir
        configured + [dir]
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
        roots = ambient_roots(@grants.read_roots)
        @core.authorize(self, Authority::Read, "read", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, roots) : @grants.check_root(path, roots)
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
        roots = ambient_roots(@grants.write_roots)
        @core.authorize(self, Authority::Write, "write", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, roots) : @grants.check_root(path, roots)
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
        roots = ambient_roots(@grants.delete_roots)
        @core.authorize(self, Authority::Delete, "delete", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, roots) : @grants.check_root(path, roots)
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
    end
  end
end
