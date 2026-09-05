require "uri"
require "yaml"

module Adjutant
  module Legate
    # `Legate::NetRule` — one entry under §7's `net.hosts`, widened
    # from the bare hostname string that section's own example shows
    # into a scheme + host + port + method tuple.
    #
    # DELIBERATE EXTENSION of LEGATE.md §7, agreed with the embedder
    # before implementing. §7 writes `hosts: ["api.example.com"]` and
    # the previous `Grants#check_host` implemented exactly that: an
    # exact string match on the hostname, nothing else. The gap that
    # closes badly is that **a host is not a service**. Granting
    # `internal.example.com` so a script can call an HTTP API on 443
    # also granted it 22, 5432 and 6379 on the same machine, over any
    # scheme, using any method. Nothing in §7 said otherwise because
    # §7 never contemplated the question.
    #
    # So a rule now pins all four. The plain-string form still parses
    # and still means what §7's example means, so no existing policy
    # file changes meaning — except that its ports and scheme are now
    # pinned to the defaults below rather than being unconstrained,
    # which is the entire point.
    #
    # Every default fails CLOSED. That is the design rule this type
    # exists to enforce, and the reason each field's default is what
    # it is:
    #
    #   - **scheme absent -> https only.** Plaintext HTTP has to be
    #     named in the policy. §8.2 makes TLS verification mandatory
    #     and non-configurable, so `scheme: http` is the only route to
    #     an unauthenticated transport, and it is visible on the line
    #     that grants it rather than inferred from a URL a script
    #     happens to construct.
    #   - **ports absent -> the scheme's default port ALONE** (443 for
    #     https, 80 for http), never "any port". This is the change
    #     that actually closes the host-versus-service gap above.
    #   - **methods absent -> whatever the grant-wide `net.methods`
    #     list allows.** A rule's own `methods:` INTERSECTS with that
    #     list and can only ever narrow it (see `#allows_method?`), so
    #     reading the single top-level line still tells you the
    #     ceiling for the whole policy — a per-rule list can never
    #     surprise you by exceeding it.
    #   - **subdomains absent -> exact host match only.**
    #
    # There is deliberately NO wildcard/glob syntax in the host
    # string. `*.example.com` and `*example.com` differ by one
    # character, mean very different things, and only one of them is a
    # disaster; a boolean cannot be typo'd into the wrong one.
    # `subdomains: true` is the single, explicit widening lever, and
    # it widens from THIS RULE'S host specifically — `x.y.com` with
    # subdomains matches `a.x.y.com` but never `a.y.com`, since the
    # rule's own host must remain a suffix of anything it admits.
    #
    # Ports are a LIST, never a range. A range is nearly always
    # over-granting by accident, and the cost of writing out the two
    # or three ports a policy actually needs is trivial next to the
    # cost of `8000-9000` quietly including something nobody checked.
    struct NetRule
      DEFAULT_PORTS = {"https" => 443, "http" => 80}

      getter host : String
      getter scheme : String
      getter ports : Array(Int32)
      getter? subdomains : Bool

      # Opt-in to reaching loopback and private address space — a
      # local Ollama on `127.0.0.1:11434`, a service on the LAN, a
      # dev server. Defaults to false, so §8.2's address check refuses
      # every internal address unless a rule says otherwise.
      #
      # The distinction this encodes: §8.2's confused-deputy problem
      # exists when a script reaches an internal address it never
      # named — a permitted public host that 302s to somewhere
      # private. If the POLICY itself names the destination, nobody is
      # confused; that is the grant working as written.
      #
      # Per RULE rather than per policy, deliberately. A policy can
      # grant `local: true` to its Ollama rule while every other host
      # in the same file still refuses to follow a redirect into
      # private space. And because each redirect hop re-authorizes
      # from scratch, a `local: true` rule grants nothing to whatever
      # it redirects to.
      #
      # Explicit rather than inferred: this is NOT deduced from the
      # host being spelled `localhost` or `127.0.0.1`, because a name
      # like `ollama.internal` resolving to `192.168.1.50` deserves
      # the same opt-in, and a flag in the YAML is greppable across a
      # fleet of policies in a way that inference never is.
      #
      # LINK-LOCAL IS NOT COVERED and cannot be opted into by any
      # rule: `169.254.0.0/16` and `fe80::/10` stay blocked
      # unconditionally. That range is what a device self-assigns when
      # DHCP fails, so almost nothing legitimate listens there — and
      # `169.254.169.254`, the cloud metadata endpoint, is the single
      # highest-value SSRF target in existence. The cost is that
      # genuine IPv6 link-local LAN addresses are unreachable too,
      # which is a real trade and a deliberate one.
      getter? local : Bool

      # Empty means "inherit the grant-wide list" — NOT "no methods."
      # The distinction matters and is why this is not defaulted to
      # something concrete here: a rule that says nothing about
      # methods must defer, and a rule that names methods must narrow.
      # Neither is expressible if this field pre-fills itself.
      getter methods : Array(String)

      def initialize(@host : String, @scheme : String = "https",
                     ports : Array(Int32)? = nil, @methods : Array(String) = [] of String,
                     @subdomains : Bool = false, @local : Bool = false)
        @ports = ports || [DEFAULT_PORTS[@scheme]? || 443]
      end

      # Parses either form §7's `net.hosts` list now accepts:
      #
      #   - a plain scalar — `api.example.com`, `api.example.com:8443`,
      #     or a full `https://api.example.com:8443`
      #   - a mapping — `{host:, scheme:, ports:, methods:, subdomains:}`
      #
      # Raises `ArgumentError` on anything it can't make sense of,
      # matching `SizeLiteral`/`DurationLiteral`'s own posture: a
      # malformed POLICY is an embedder error surfaced loudly at load
      # time, not a silently-denied grant discovered at call time.
      def self.from_yaml_node(node : YAML::Any) : NetRule
        if scalar = node.as_s?
          return parse(scalar)
        end

        hash = node.as_h?
        raise ArgumentError.new("Legate::Grants — a net.hosts entry must be a string or a mapping, got #{node.raw.class}") unless hash

        raw_host = hash[YAML::Any.new("host")]?.try(&.as_s?)
        raise ArgumentError.new("Legate::Grants — a net.hosts mapping entry needs a `host:` key") unless raw_host

        scheme = hash[YAML::Any.new("scheme")]?.try(&.as_s?).try(&.downcase) || "https"
        validate_scheme!(scheme)

        ports = hash[YAML::Any.new("ports")]?.try(&.as_a?).try do |list|
          list.map do |entry|
            port = entry.as_i? || entry.as_s?.try(&.to_i32?)
            raise ArgumentError.new("Legate::Grants — net.hosts port #{entry.raw.inspect} is not an integer") unless port
            validate_port!(port)
            port
          end
        end

        methods = hash[YAML::Any.new("methods")]?.try(&.as_a?).try(&.map(&.as_s.downcase)) || [] of String
        subdomains = hash[YAML::Any.new("subdomains")]?.try(&.as_bool?) || false
        local = hash[YAML::Any.new("local")]?.try(&.as_bool?) || false

        new(host: normalize_host(raw_host), scheme: scheme, ports: ports,
          methods: methods, subdomains: subdomains, local: local)
      end

      # The scalar form. Three spellings, resolved by inspection
      # rather than by trying `URI.parse` on everything — `URI.parse`
      # accepts a bare hostname perfectly happily and returns it as a
      # PATH with no host at all, which would silently produce a rule
      # matching nothing.
      def self.parse(raw : String) : NetRule
        str = raw.strip
        raise ArgumentError.new("Legate::Grants — empty net.hosts entry") if str.empty?

        # An IPv6 literal needs brackets to be unambiguous with the
        # port separator, and nothing here handles that yet — see
        # SCOPE.md. Rejected loudly rather than mis-split on the first
        # colon, which would produce a rule for a host that doesn't
        # exist and deny every real connection to it with a confusing
        # reason.
        if str.includes?('[') || str.count(':') > 1 && !str.includes?("://")
          raise ArgumentError.new("Legate::Grants — IPv6 literals are not supported in net.hosts yet: #{raw.inspect}")
        end

        str.includes?("://") ? parse_uri_form(str, raw) : parse_host_port_form(str, raw)
      end

      # `scheme://host[:port]`. Split out from `parse` (2026-09-02)
      # rather than disabling the complexity rule: the two accepted
      # spellings share nothing but the validation helpers, and reading
      # either one no longer means stepping over the other.
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

      # The bare `host[:port]` spelling §7 shows, which takes the
      # scheme default rather than stating one.
      private def self.parse_host_port_form(str : String, raw : String) : NetRule
        host, _, port_str = str.partition(':')
        raise ArgumentError.new("Legate::Grants — net.hosts entry #{raw.inspect} has no host") if host.empty?
        return new(host: normalize_host(host)) if port_str.empty?

        port = port_str.to_i32?
        raise ArgumentError.new("Legate::Grants — net.hosts entry #{raw.inspect} has a non-numeric port") unless port
        validate_port!(port)
        new(host: normalize_host(host), ports: [port])
      end

      # Hostnames are case-insensitive (RFC 4343) and a trailing dot
      # denotes the same absolute name, so both are normalised away
      # here rather than at every comparison site. Without this,
      # `API.example.com` and `api.example.com.` would each be a
      # silent no-match against an `api.example.com` rule — a denial
      # that looks like a policy bug and is very hard to spot by
      # reading the YAML.
      private def self.normalize_host(host : String) : String
        host.downcase.rstrip('.')
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
        normalized = candidate.downcase.rstrip('.')
        return true if normalized == host
        # Widening from THIS rule's host, with the dot boundary as
        # part of the suffix — `.b.com` rather than `b.com`, so
        # `evilb.com` cannot match a rule for `b.com`. That missing
        # dot is the classic subdomain-matching bug and the reason
        # this is one method rather than an `ends_with?` at each call
        # site.
        subdomains? && normalized.ends_with?(".#{host}")
      end

      def matches_scheme?(candidate : String) : Bool
        candidate.downcase == scheme
      end

      def matches_port?(candidate : Int32) : Bool
        ports.includes?(candidate)
      end

      # Narrowing only, never widening. `grant_methods` is §7's
      # top-level `net.methods`; this rule's own list can subtract
      # from it but cannot add to it, so the top-level line is always
      # a true ceiling for the whole policy.
      def allows_method?(candidate : String, grant_methods : Array(String)) : Bool
        method = candidate.downcase
        return false unless grant_methods.includes?(method)
        methods.empty? || methods.includes?(method)
      end

      # For denial reasons — the string a human reads when a fatal,
      # unrescuable `Legate::Denied` stops their run, so it is worth
      # spelling out the rule in the same shape the policy file did.
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
