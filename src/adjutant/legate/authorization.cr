require "./grants"

module Adjutant
  module Legate
    # Reopens Grants (grants.cr) to add the pure STATIC checks a
    # verb's broker call goes through before anything else happens —
    # the roots/hosts/binaries allowlist half of §8, kept separate
    # from grants.cr's own config-parsing concern so each file stays
    # about one thing. `RiskFlowPolicy`'s dynamic, taint-driven check
    # is a completely separate step the broker (4c) runs AFTER these
    # pass, never instead of them — see the design conversation this
    # session had on how Grants and RiskFlowPolicy relate.
    #
    # Deliberately narrow: these three methods cover exactly what a
    # Grants config can decide on its own (does this belong to an
    # allowed root/host/binary set), not the runtime hardening §8.2
    # (SSRF/DNS-range checks, which need a real network call) and
    # §8.3 (exec sandboxing) call for, nor §8.1's own step 3
    # (immediately-before-use re-check right at the open() call) —
    # those need a concrete verb to attach to and land with the verb
    # surface in step 5.
    class Grants
      # A static-check outcome. `allowed?` is the broker's fast-path
      # branch; `reason` is a human-readable explanation of a denial,
      # written to end up directly in a `Legate::Denied` message
      # rather than requiring the broker to reconstruct one. Denied
      # decisions from different methods below use different reason
      # shapes on purpose (some name a resolved absolute path, some
      # don't) — the broker is expected to display `reason` as-is, not
      # parse it.
      struct Decision
        getter? allowed : Bool
        getter reason : String?

        def initialize(@allowed : Bool, @reason : String? = nil)
        end

        def self.allow : Decision
          new(true)
        end

        def self.deny(reason : String) : Decision
          new(false, reason)
        end
      end

      # §8.1 steps 1–2 (amended check-then-open approach — see
      # LEGATE.md §8.1's own rewritten text and this session's design
      # note on the residual TOCTOU race being accepted, not closed).
      # Resolves `path` with `File.realpath` and confirms the result
      # falls under one of `roots` (also realpath'd, so a symlinked
      # root and a symlinked path compare on equal footing). Which
      # roots array to check is the CALLER's choice — this method
      # doesn't know about `read` vs `write` vs `delete`, it just
      # tests containment against whatever list it's handed, so one
      # implementation serves all three grant categories.
      #
      # Only covers a path that already EXISTS. A verb creating a new
      # file (e.g. `write` to a path that doesn't exist yet) has
      # nothing for `File.realpath` to resolve — that case needs the
      # verb to realpath the PARENT directory instead and is properly
      # step 5's problem (it's specific to what the verb is actually
      # doing), not this general-purpose check's.
      def check_root(path : String, roots : Array(String)) : Decision
        return Decision.deny("no roots granted for this operation") if roots.empty?

        real_path = resolve(path)
        return Decision.deny("#{path} does not exist or could not be resolved") unless real_path

        under_root = roots.any? do |root|
          real_root = resolve(root)
          real_root && (real_path == real_root || real_path.starts_with?(real_root.chomp('/') + "/"))
        end

        under_root ? Decision.allow : Decision.deny("#{path} (resolved: #{real_path}) is not under any granted root")
      end

      # Allowlist membership only — exact string match against
      # `net_hosts`. No wildcard/subdomain matching (§7's own example
      # lists exact hostnames, not patterns) and no SSRF/DNS-resolved-
      # address-range check (§8.2) — that needs the actual connection
      # attempt's resolved address, which only exists once a `net`
      # verb is mid-call, so it's deferred there.
      def check_host(host : String) : Decision
        return Decision.deny("no hosts granted") if net_hosts.empty?
        net_hosts.includes?(host) ? Decision.allow : Decision.deny("#{host} is not in the granted host allowlist")
      end

      # Resolves `binary` to an absolute path — a bare name (no `/`)
      # is searched for on `PATH`, same as a shell would; anything
      # containing `/` is realpath'd directly — then compares that
      # resolution against `exec_binaries` (also realpath'd, so an
      # allowlist entry that's itself a symlink still matches).
      # Comparing POST-resolution on both sides is the point: it's
      # what stops a `PATH` trick or a symlinked allowlist entry from
      # producing a false allow or a false deny.
      def check_binary(binary : String) : Decision
        return Decision.deny("no binaries granted") if exec_binaries.empty?

        real_binary = resolve_binary(binary)
        return Decision.deny("#{binary} could not be resolved to an executable path") unless real_binary

        allowed = exec_binaries.any? { |candidate| resolve(candidate) == real_binary }
        allowed ? Decision.allow : Decision.deny("#{binary} (resolved: #{real_binary}) is not in the granted binary allowlist")
      end

      # `File.realpath` wrapped to return nil instead of raising —
      # every caller above treats "doesn't exist / can't be resolved"
      # as a plain denial reason, not a Crystal-level exception
      # propagating out of a static check. NOT independently verified
      # against a live toolchain — `File.realpath`'s exact raised
      # exception type on a missing path is written from recollection
      # (`File::NotFoundError` broadened to a bare `rescue` here
      # specifically because getting the exact type wrong would be
      # worse than catching one exception type too many in a helper
      # whose only job is "turn failure into nil").
      private def resolve(path : String) : String?
        File.realpath(path)
      rescue
        nil
      end

      # `binary` with no `/` is a bare command name — searched across
      # `PATH` the way a shell resolves `argv[0]`, checking each
      # directory in order and taking the first existing, executable
      # match. `binary` containing `/` is treated as a path already
      # and resolved directly, no `PATH` search. Either way the
      # result is realpath'd before returning, so `check_binary`'s
      # comparison above is always resolved-path-to-resolved-path.
      private def resolve_binary(binary : String) : String?
        return resolve(binary) if binary.includes?('/')

        path_env = ENV["PATH"]? || ""
        path_env.split(':').each do |dir|
          next if dir.empty?
          candidate = File.join(dir, binary)
          real = resolve(candidate)
          return real if real && File.file?(real) && File::Info.executable?(real)
        end
        nil
      end
    end
  end
end
