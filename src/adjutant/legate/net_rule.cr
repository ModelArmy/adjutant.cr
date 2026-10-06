require "uri"
require "yaml"
require "../host_name"

module Adjutant
  module Legate
    # One `net.hosts` entry (LEGATE.md §7): a scheme, host, ports and
    # methods, each defaulting closed. With no scheme, https only; with
    # no ports, the scheme's default port alone; with no methods, the
    # grant-wide `net.methods`, which a rule can narrow but never
    # widen; with no `subdomains`, the exact host only. There is no
    # wildcard syntax and no port range.
    struct NetRule
      DEFAULT_PORTS = {"https" => 443, "http" => 80}

      getter host : String
      getter scheme : String
      getter ports : Array(Int32)
      getter? subdomains : Bool

      # Whether this rule may reach loopback and private addresses
      # (§8.2), for a local model server or a LAN service. Per rule, and
      # never inferred from the host's spelling. Link-local, including
      # the cloud metadata address 169.254.169.254, stays refused
      # whatever this says.
      getter? local : Bool

      # Empty inherits the grant-wide list; it doesn't mean no
      # methods.
      getter methods : Array(String)

      def initialize(@host : String, @scheme : String = "https",
                     ports : Array(Int32)? = nil, @methods : Array(String) = [] of String,
                     @subdomains : Bool = false, @local : Bool = false)
        @ports = ports || [DEFAULT_PORTS[@scheme]? || 443]
      end

      MAPPING_KEYS = {"host", "scheme", "ports", "methods", "subdomains", "local"}

      # Parses a scalar (`api.example.com`, `api.example.com:8443`,
      # `https://api.example.com:8443`) or a mapping (`host`, `scheme`,
      # `ports`, `methods`, `subdomains`, `local`). Raises ArgumentError
      # for anything malformed, including an unknown key or a value of
      # the wrong type, so a bad policy fails when loaded.
      def self.from_yaml_node(node : YAML::Any) : NetRule
        if scalar = node.as_s?
          return parse(scalar)
        end
        unless node.as_h?
          raise YamlPolicy.invalid("grants.net.hosts", "entries must be strings or mappings, got #{node.raw.inspect}")
        end

        hash = YamlPolicy.mapping(node, "a grants.net.hosts mapping", MAPPING_KEYS)
        raw_host = YamlPolicy.string(hash, "host", "grants.net.hosts host")
        raise YamlPolicy.invalid("a grants.net.hosts mapping", "needs a `host:` key") unless raw_host

        scheme = YamlPolicy.string(hash, "scheme", "grants.net.hosts scheme").try(&.downcase) || "https"
        validate_scheme!(scheme)

        ports = ports_of(hash)
        methods = YamlPolicy.strings(hash, "methods", "grants.net.hosts methods").map(&.downcase)
        # Absent inherits `net.methods`; an empty list would too, which
        # is the opposite of what it seems to say.
        if YamlPolicy.value(hash, "methods") && methods.empty?
          raise YamlPolicy.invalid("grants.net.hosts methods", "is empty; list at least one method, or leave it out to inherit net.methods")
        end
        subdomains = YamlPolicy.bool(hash, "subdomains", "grants.net.hosts subdomains", false)
        local = YamlPolicy.bool(hash, "local", "grants.net.hosts local", false)

        new(host: normalize_host(raw_host), scheme: scheme, ports: ports,
          methods: methods, subdomains: subdomains, local: local)
      end

      # The `ports:` list, or nil for the scheme's default port. An
      # empty list is refused, as it would grant no port while reading
      # as the default.
      private def self.ports_of(hash : YamlPolicy::Mapping) : Array(Int32)?
        return unless YamlPolicy.value(hash, "ports")
        entries = YamlPolicy.list(hash, "ports", "grants.net.hosts ports")
        raise YamlPolicy.invalid("grants.net.hosts ports", "is empty; list at least one port, or leave it out for the scheme's default") if entries.empty?
        entries.map do |entry|
          port = entry.as_i64?
          raise YamlPolicy.invalid("grants.net.hosts ports", "must list whole numbers, got #{entry.raw.inspect}") unless port
          raise ArgumentError.new("Legate::Grants — net.hosts port #{port} is out of range") unless port > 0 && port <= 65_535
          port.to_i32
        end
      end

      # The scalar form, split by inspection: `URI.parse` reads a bare
      # hostname as a path with no host, which would match nothing.
      def self.parse(raw : String) : NetRule
        str = raw.strip
        raise ArgumentError.new("Legate::Grants — empty net.hosts entry") if str.empty?

        # IPv6 literals are rejected: a bracketed host isn't parsed,
        # and splitting on the first colon would name the wrong host.
        if str.includes?('[') || str.count(':') > 1 && !str.includes?("://")
          raise ArgumentError.new("Legate::Grants — IPv6 literals are not supported in net.hosts yet: #{raw.inspect}")
        end

        str.includes?("://") ? parse_uri_form(str, raw) : parse_host_port_form(str, raw)
      end

      # `scheme://host[:port]`.
      private def self.parse_uri_form(str : String, raw : String) : NetRule
        uri = URI.parse(str)
        scheme = (uri.scheme || "https").downcase
        validate_scheme!(scheme)
        host = uri.host
        raise ArgumentError.new("Legate::Grants — net.hosts entry #{raw.inspect} has no host") if host.nil? || host.empty?
        port = uri.port
        validate_port!(port) if port
        new(host: normalize_host(host), scheme: scheme, ports: port ? [port] : nil)
      end

      # `host[:port]`, with the default scheme.
      private def self.parse_host_port_form(str : String, raw : String) : NetRule
        host, _, port_str = str.partition(':')
        raise ArgumentError.new("Legate::Grants — net.hosts entry #{raw.inspect} has no host") if host.empty?
        return new(host: normalize_host(host)) if port_str.empty?

        port = port_str.to_i32?
        raise ArgumentError.new("Legate::Grants — net.hosts entry #{raw.inspect} has a non-numeric port") unless port
        validate_port!(port)
        new(host: normalize_host(host), ports: [port])
      end

      # As DNS compares names; see `HostName`.
      private def self.normalize_host(host : String) : String
        HostName.fold_host(host)
      end

      private def self.validate_scheme!(scheme : String) : Nil
        return if scheme == "https" || scheme == "http"
        raise ArgumentError.new("Legate::Grants — net.hosts scheme must be http or https, got #{scheme.inspect}")
      end

      private def self.validate_port!(port : Int32) : Nil
        return if port > 0 && port <= 65_535
        raise ArgumentError.new("Legate::Grants — net.hosts port #{port} is out of range")
      end

      def matches_host?(candidate : String) : Bool
        normalized = HostName.fold_host(candidate)
        return true if normalized == host
        # The suffix includes the dot, so a rule for `b.com` doesn't
        # match `evilb.com`.
        subdomains? && normalized.ends_with?(".#{host}")
      end

      def matches_scheme?(candidate : String) : Bool
        candidate.downcase == scheme
      end

      def matches_port?(candidate : Int32) : Bool
        ports.includes?(candidate)
      end

      # Whether `candidate` is in `grant_methods` and, if this rule
      # names methods, in its own list too.
      def allows_method?(candidate : String, grant_methods : Array(String)) : Bool
        method = candidate.downcase
        return false unless grant_methods.includes?(method)
        methods.empty? || methods.includes?(method)
      end

      # The rule as a policy would spell it, for denial messages.
      def to_s(io : IO) : Nil
        io << scheme << "://" << host
        io << ":" << ports.join(",")
        io << " (+subdomains)" if subdomains?
        io << " (+local)" if local?
        io << " methods=" << methods.join(",") unless methods.empty?
      end
    end
  end
end
