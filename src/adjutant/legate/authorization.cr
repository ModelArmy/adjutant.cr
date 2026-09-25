require "./grants"

module Adjutant
  module Legate
    # Adds the static network check and the `ambient.env` allowlist
    # check to Legate::Grants. The resolved-address checks of §8.2 are
    # made by `Legate.fetch` during the call, and the risk-flow check
    # runs after these pass.
    class Grants
      # The rules that allow this connection: any rule matching all of
      # scheme, host, port and method. Returned as rules rather than a
      # Bool, since `Legate.fetch` needs to know whether the matched
      # rule has `local: true`. `check_net` gives the decision, whose
      # denial reason names the closest miss ("port 22 is not in
      # [443]"), since a denial ends the run.
      def matching_net_rules(scheme : String, host : String, port : Int32, method : String) : Array(NetRule)
        return [] of NetRule if net_rules.empty? || net_methods.empty?
        net_rules.select do |rule|
          rule.matches_host?(host) && rule.matches_scheme?(scheme) &&
            rule.matches_port?(port) && rule.allows_method?(method, net_methods)
        end
      end

      # Whether a matching rule has `local: true`. Link-local stays
      # refused regardless.
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

      # Allows `name` only if the `ambient.env` allowlist has it,
      # compared case-sensitively, as POSIX names are.
      def check_ambient_env(name : String) : Decision
        return Decision.deny("no ambient.env names granted") if ambient_env.empty?
        return Decision.allow if ambient_env.includes?(name)
        Decision.deny("#{name.inspect} is not in the ambient.env allowlist")
      end
    end
  end
end
