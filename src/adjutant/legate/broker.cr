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
    # Legate's EffectProvider (LEGATE.md §8). Holds Legate's
    # perimeter (`grants`), `Legate.log`'s destination and the scratch
    # directory, and wraps the run's shared `Adjutant::Broker` with
    # one `authorize_*` method per grant category. Every effectful
    # verb, and `Legate.env`, calls exactly one of them before
    # touching anything outside the VM. A denial raises
    # `Legate::Denied`.
    class Broker
      include ::Adjutant::EffectProvider

      # The run's shared broker, used rather than inherited.
      getter core : ::Adjutant::Broker

      delegate budget, audit_log, open_sources, to: @core

      def provider_name : String
        "Legate"
      end

      # The class a perimeter denial raises (§9.2's fatal tier).
      def denied_class_name : String
        "Legate::Denied"
      end

      # The grant categories this provider authorizes. `Ambient` is
      # here for `Legate.env`'s allowlist; `Log` isn't, since
      # `Legate.log` has no grant, only the risk-flow sink check.
      def authorities : Set(Authority)
        AUTHORITIES
      end

      AUTHORITIES = Set{Authority::Read, Authority::Write, Authority::Delete, Authority::Net, Authority::Ambient}

      # Read by verbs to clamp their own limits, such as
      # `Legate.read`'s `limit:` against `read_limit`.
      getter grants : Grants

      # `Legate.log`'s destination (§4.7). The host supplies its own
      # `::Log`; the default is bound to an empty builder, so an
      # unconfigured `Legate.log` goes nowhere. A plain
      # `::Log.for(...)` would print Info and above to STDOUT, which
      # is Crystal's default for any source when `Log.setup` hasn't
      # been called.
      getter log : ::Log

      # A builder with no bindings, for `DEFAULT_LOG`.
      DEFAULT_LOG_BUILDER = ::Log::Builder.new
      DEFAULT_LOG         = DEFAULT_LOG_BUILDER.for("adjutant.legate")

      # `Legate.scratch`'s directory (§4.7), created on first use and
      # removed when the run ends (`cleanup_scratch!`, called by
      # `Interpreter#eval`). One run is one `eval`; persistent space
      # is what a `write:` grant is for.
      @scratch_dir : String? = nil

      # Pass one `core` to every provider in a run, since the budget,
      # audit log and open sources are per run. Without one, a broker
      # is built from `budget` and `audit_log`, which are ignored when
      # `core` is given.
      def initialize(grants : Grants, core : ::Adjutant::Broker? = nil,
                     budget : Budget? = nil, audit_log : AuditLog = AuditLog.new,
                     @log : ::Log = DEFAULT_LOG)
        @grants = grants
        @core = core || ::Adjutant::Broker.new(grants.limits, budget, audit_log)
      end

      # Creates the scratch directory on first call, under the system
      # temp directory.
      def scratch_dir : String
        @scratch_dir ||= begin
          dir = File.tempname("adjutant-legate-scratch", nil)
          FileUtils.mkdir_p(dir)
          dir
        end
      end

      # Removes the scratch directory if one was created, and forgets
      # it. Returns any exception rather than raising, since it runs
      # in an `ensure`, as `OpenSources#close_all` does.
      def cleanup_scratch! : Exception?
        return unless dir = @scratch_dir
        FileUtils.rm_rf(dir)
        nil
      rescue ex
        ex
      ensure
        @scratch_dir = nil
      end

      # The configured roots plus the scratch directory, if created.
      # Grants never change during a run (§7); scratch is writable from
      # the start (§4.7) and only its path is created later.
      private def ambient_roots(configured : Array(String)) : Array(String)
        return configured unless dir = @scratch_dir
        configured + [dir]
      end

      # Raises `too_many` (`Legate::TooMany`, passed in because nested
      # Legate classes can't be looked up by name) when
      # `max_open_streams` are already open. Call before opening the
      # handle, so a refusal leaves nothing to close. Resource
      # accounting for a call already authorized: no grant, no audit
      # record.
      def check_stream_capacity!(ncc : NativeCallContext, too_many : RubyClass) : Nil
        return unless open_sources.at_capacity?
        ncc.raise_error_class(
          "#{open_sources.max_open} streams are already open — finish walking one before opening another, " \
          "or raise max_open_streams in the policy's limits",
          too_many,
        )
      end

      # Registers a stream source for the rest of the run. Call
      # `check_stream_capacity!` before opening it.
      def register_source(source : Closable) : Nil
        open_sources.register(source)
      end

      # The `read` grant (§4.1), for a path the verb has already
      # extracted. With `allow_missing`, a path that doesn't exist is
      # checked for containment rather than denied, for verbs where
      # missing means nil (§2.3).
      def authorize_read(path : String, ncc : NativeCallContext, allow_missing : Bool = false) : RiskFlowLabel?
        roots = ambient_roots(@grants.read_roots)
        @core.authorize(self, Authority::Read, "read", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, roots) : @grants.check_root(path, roots)
        end
      end

      # The `write` grant (§4.3). Pass `allow_missing` for a target
      # that may not exist yet, the normal case for a write.
      def authorize_write(path : String, ncc : NativeCallContext, allow_missing : Bool = false) : RiskFlowLabel?
        roots = ambient_roots(@grants.write_roots)
        @core.authorize(self, Authority::Write, "write", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, roots) : @grants.check_root(path, roots)
        end
      end

      # The `delete` grant (§4.4). Pass `allow_missing` where a
      # missing path is a result, not an error: `rm` returns 0 for it,
      # `mv` raises `Legate::NotFound`. Without it, a missing path is a
      # fatal denial even inside a granted root.
      def authorize_delete(path : String, ncc : NativeCallContext, allow_missing : Bool = false) : RiskFlowLabel?
        roots = ambient_roots(@grants.delete_roots)
        @core.authorize(self, Authority::Delete, "delete", path, ProvenanceKind::File, ncc) do
          allow_missing ? @grants.check_root_maybe_missing(path, roots) : @grants.check_root(path, roots)
        end
      end

      # Whether the rule that authorized this connection has
      # `local: true`, which `Legate.fetch` asks after `authorize_net`
      # to decide which resolved addresses to accept.
      def net_allows_local?(scheme : String, host : String, port : Int32, method : String) : Bool
        @grants.net_allows_local?(scheme, host, port, method)
      end

      # The `net` grant (§4.5): scheme, host, port and method against
      # the net rules. Static only; `Legate.fetch` checks the resolved
      # addresses itself (§8.2). The audit subject and the sensitivity
      # origin are `scheme://host:port`, so a policy pattern can tell
      # ports apart.
      def authorize_net(scheme : String, host : String, port : Int32, method : String,
                        ncc : NativeCallContext) : RiskFlowLabel?
        subject = "#{scheme}://#{host}:#{port}"
        @core.authorize(self, Authority::Net, "net", subject, ProvenanceKind::Host, ncc) do
          @grants.check_net(scheme, host, port, method)
        end
      end

      # The `ambient.env` allowlist (§4.7). Returns the label for the
      # variable's value, whether or not the variable is set, so
      # sensitivity is checked before existence.
      def authorize_env(name : String, ncc : NativeCallContext) : RiskFlowLabel?
        @core.authorize(self, Authority::Ambient, "env", name, ProvenanceKind::Env, ncc) do
          @grants.check_ambient_env(name)
        end
      end
    end
  end
end
