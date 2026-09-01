require "./grants"

module Adjutant
  module Legate
    # Reopens Legate::Grants (grants.cr) to add the STATIC network
    # check, kept separate from grants.cr's own config-parsing concern
    # so each file stays about one thing.
    #
    # The root and binary checks that used to live here moved to
    # `Adjutant::Grants` on 2026-09-01 — containment under a root and
    # membership in a binary allowlist say nothing about Legate. What
    # remains is the part that does: authorizing a connection needs
    # the protocol's own vocabulary (HTTP methods), and core has no
    # business holding that. See SCOPE.md.
    #
    # `RiskFlowPolicy`'s dynamic, taint-driven check is a completely
    # separate step the broker runs AFTER this passes, never instead
    # of it.
    #
    # Deliberately narrow: this covers exactly what a Grants config
    # can decide on its own, not the runtime hardening §8.2
    # (SSRF/DNS-range checks, which need a real network call) or §8.3
    # (exec sandboxing) call for, nor §8.1's own step 3
    # (immediately-before-use re-check right at the open() call) —
    # those need a live connection or a real process to attach to.
    class Grants
      # Replaces the old `check_host`, which matched a hostname string
      # and nothing else. A connection is now authorized against all
      # four of scheme, host, port and method together, because any
      # three of them without the fourth is not a service — see
      # net_rule.cr's own top comment for the full reasoning and for
      # why each default fails closed.
      #
      # Still allowlist semantics: ANY rule matching all four allows.
      # Still no SSRF/DNS-resolved-address-range check (§8.2) — that
      # needs the actual connection attempt's resolved addresses,
      # which only exist once `Legate.fetch` is mid-call, so it stays
      # deferred there. This method is the STATIC half only.
      #
      # The denial reason names the closest miss rather than a bare
      # "denied". A `net` denial is FATAL and unrescuable, so it ends
      # the run; being told "host matched, port 22 is not in [443]"
      # rather than "denied" is the difference between a one-line
      # policy fix and an afternoon.
      # The rules that authorize this exact connection — all four of
      # scheme, host, port and method. Separate from `check_net`
      # because a caller needs more than allowed/denied: `Legate.fetch`
      # has to know whether the MATCHED rule opted into loopback and
      # private address space (`local: true`) before it can vet the
      # resolved addresses. Returning the rules rather than a bare
      # boolean keeps that decision where the rule is.
      def matching_net_rules(scheme : String, host : String, port : Int32, method : String) : Array(NetRule)
        return [] of NetRule if net_rules.empty? || net_methods.empty?
        net_rules.select do |rule|
          rule.matches_host?(host) && rule.matches_scheme?(scheme) &&
            rule.matches_port?(port) && rule.allows_method?(method, net_methods)
        end
      end

      # Whether any rule authorizing this connection permits loopback
      # and private address space. False unless a matching rule says
      # `local: true` — see `NetRule#local?`, and note that link-local
      # is never covered by it.
      def net_allows_local?(scheme : String, host : String, port : Int32, method : String) : Bool
        matching_net_rules(scheme, host, port, method).any?(&.local?)
      end

      def check_net(scheme : String, host : String, port : Int32, method : String) : Decision
        return Decision.deny("no hosts granted") if net_rules.empty?
        return Decision.deny("no methods granted (net.methods is empty)") if net_methods.empty?

        host_matches = net_rules.select(&.matches_host?(host))
        if host_matches.empty?
          return Decision.deny("#{host} is not in the granted host allowlist")
        end

        scheme_matches = host_matches.select(&.matches_scheme?(scheme))
        if scheme_matches.empty?
          return Decision.deny("#{scheme}://#{host} denied: #{host} is granted only over #{host_matches.map(&.scheme).uniq!.join("/")}")
        end

        port_matches = scheme_matches.select(&.matches_port?(port))
        if port_matches.empty?
          allowed = scheme_matches.flat_map(&.ports).uniq!.sort!
          return Decision.deny("#{scheme}://#{host}:#{port} denied: port #{port} is not in #{allowed}")
        end

        if port_matches.any?(&.allows_method?(method, net_methods))
          Decision.allow
        else
          Decision.deny("#{method.upcase} #{scheme}://#{host}:#{port} denied: method #{method.upcase} is not granted for this host")
        end
      end

      # Resolves `binary` to an absolute path — a bare name (no `/`)
      # is searched for on `PATH`, same as a shell would; anything
      # containing `/` is realpath'd directly — then compares that
      # resolution against `exec_binaries` (also realpath'd, so an
      # allowlist entry that's itself a symlink still matches).
      # Comparing POST-resolution on both sides is the point: it's
      # what stops a `PATH` trick or a symlinked allowlist entry from
      # producing a false allow or a false deny.

    end
  end
end
