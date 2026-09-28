require "http/client"
require "openssl"
require "../http_client_pinning"
require "socket"
require "uri"
require "../broker"
require "../response"
require "../exceptions"
require "../helpers"
require "../../native_call_context"
require "../../utils/http_response_stream"

module Adjutant
  module Legate
    module Verbs
      # `Legate.fetch(url, method:, headers:, body:, stream:, timeout:,
      # limit:, redirects:) -> Legate::Response` (LEGATE.md §4.5).
      #
      # Transport failures raise; HTTP statuses don't. A 500 is an
      # answer and a DNS failure is not; `Response#raise!` lets a script
      # treat a status as an error.
      #
      # Each hop is authorized, resolved to every address, checked
      # against the blocked ranges, and connected to one pinned address
      # (§8.2; see http_client_pinning.cr). Every hop reuses the call's
      # headers until a redirect leaves the first hop's origin; from
      # then on only `REDIRECT_HEADERS` and those the grants'
      # `net_redirect_headers` names are sent.
      #
      # `stream: true` returns a `Legate::Bytes` whose iterator owns the
      # connection for the walk. `HTTP::Client#exec` either buffers the
      # body or closes the connection when its block returns, so
      # `Utils::HttpResponseStream` keeps the block open on its own
      # fiber and passes chunks over a channel. An Array `body:` is
      # joined into one String before sending.
      module Fetch
        KWARG_NAMES = Set{"method", "headers", "body", "stream", "timeout", "limit", "redirects"}

        DEFAULT_METHOD    = "get"
        DEFAULT_TIMEOUT   = 30
        DEFAULT_REDIRECTS =  5

        # Request headers always sent past a redirect to another
        # origin, lowercase: content negotiation and identification,
        # never credentials. Grants add to them.
        REDIRECT_HEADERS = Set{"accept", "accept-language", "content-type", "user-agent"}

        # Bodies are read in pieces, so `limit` is enforced as bytes
        # arrive (§8.2) rather than after a full buffer exists.
        READ_CHUNK_SIZE = 65_536

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          transport = Helpers.fetch(legate, interp, "Transport")
          timeout_cls = Helpers.fetch(legate, interp, "Timeout")
          too_large = Helpers.fetch(legate, interp, "TooLarge")
          redirect = Helpers.fetch(legate, interp, "Redirect")
          too_many = Helpers.fetch(legate, interp, "TooMany")
          response_cls = Helpers.fetch(legate, interp, "Response")
          # `stream: true` returns the same `Legate::Bytes` type as
          # `Legate.bytes`.
          bytes_cls = Helpers.fetch(legate, interp, "Bytes")
          chunk_cls = Helpers.fetch(legate, interp, "Chunk")

          # A Net sink: labelled data in the URL, `body:` or
          # `headers:` is checked against policy. Keywords are checked
          # as positional arguments are.
          legate.define_native_singleton_method(
            interp.symbols.intern("fetch").value,
            RiskProfile.new(
              effects: Set{Effect::NetworkEgress},
              # Egress can't be undone.
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
            KWARG_NAMES,
            authorities: Set{Authority::Net},
          ) do |args, _blk, ncc|
            # Every keyword is validated before authorizing.
            opts = Options.read(ncc, broker, transport)

            url_val = args[1]? || Value.nil_value
            url_str_val = ncc.call_method(url_val, "to_s", [] of Value)
            raw_url = url_str_val.as_string
            label = url_str_val.label

            # The URL length cap (`url_limit`), checked before
            # authorizing, so an over-long URL is never authorized,
            # resolved or audited.
            url_limit = broker.grants.limits.url_limit
            if raw_url.bytesize > url_limit
              ncc.raise_error_class("Legate.fetch — URL is #{raw_url.bytesize} bytes, over the #{url_limit}-byte url_limit", too_large)
            end

            current_url = raw_url
            hops = 0
            redirect_headers = REDIRECT_HEADERS + broker.grants.net_redirect_headers.to_set
            origin = parse_uri(raw_url, ncc, transport)

            loop do
              target = parse_uri(current_url, ncc, transport)
              scheme = target.scheme
              host = target.host
              port = target.port

              # The script's headers go only to the first hop's origin: a
              # redirect elsewhere, even to a host the policy allows,
              # drops all but `redirect_headers`, for the rest of the
              # call. Credentials often travel in headers nobody could
              # list in advance (`X-Api-Key`), so what may pass is listed
              # instead of what may not.
              opts = opts.for_hop(target, origin, redirect_headers)

              # Every hop is authorized afresh (§8.2), so a redirect to
              # a host outside the allowlist is a fatal denial.
              label = RiskFlowLabel.join(label, broker.authorize_net(scheme, host, port, opts.method, ncc))

              addresses = resolve(host, port, ncc, transport)
              allow_local = broker.net_allows_local?(scheme, host, port, opts.method)
              check_addresses!(addresses, host, allow_local, ncc, transport)

              # The first address is pinned: every address has passed
              # `check_addresses!`. Streaming requests open every hop
              # through `HttpResponseStream`, since whether a hop is the
              # last is known only from its status and `Location`,
              # which it exposes before the body; a redirect hop is
              # closed unread.
              if opts.stream?
                # The stream cap is checked before connecting.
                broker.check_stream_capacity!(ncc, too_many)

                streamed = perform_streaming(target, addresses.first, opts, ncc, transport, timeout_cls)
                location = redirect_target_of(streamed.status, streamed.headers)

                if location
                  # Closed on every redirect path before anything can
                  # raise. Not an `ensure`: the final hop's connection
                  # must stay open.
                  streamed.close
                  raise_payload_redirect(ncc, redirect, streamed.status, location, label) if opts.payload?

                  if hops < opts.redirects
                    hops += 1
                    current_url = absolutize(location, target.uri)
                    next
                  end

                  ncc.raise_error_class("Legate.fetch — more than #{opts.redirects} redirects following #{raw_url}", transport)
                end

                iterator = ResponseChunkIterator.new(streamed, opts.limit, chunk_cls, label, broker, ncc, too_large)
                broker.register_source(iterator)

                break Legate::Response.build(
                  interp, response_cls, streamed.status, streamed.header_hash,
                  Value.robject(StreamObject.new(bytes_cls, iterator)), current_url, label,
                )
              end

              response = perform(target, addresses.first, opts, ncc, transport, timeout_cls, too_large, broker)

              location = redirect_target(response)

              # A redirect of a request that carried a body raises
              # `Legate::Redirect` rather than being followed (§4.5):
              # 307 and 308 would resend the body, possibly to another
              # host, and 301 to 303 would turn it into a GET that
              # looks like success. The rule keys on the body, not the
              # method or status; `Redirect#status` lets a script follow
              # a 303 itself.
              if location && opts.payload?
                raise_payload_redirect(ncc, redirect, response.status_code, location, label)
              end

              if location && hops < opts.redirects
                hops += 1
                current_url = absolutize(location, target.uri)
                next
              end

              if location
                ncc.raise_error_class("Legate.fetch — more than #{opts.redirects} redirects following #{raw_url}", transport)
              end

              break Legate::Response.build(
                interp, response_cls, response.status_code, response.headers,
                Value.string(response.body, label), current_url, label,
              )
            end
          end
        end

        # Every keyword, read and type-checked. `limit` is clamped to
        # the policy cap; a smaller value is honoured.
        struct Options
          getter method : String
          getter headers : Hash(String, String)
          getter body : String?
          getter timeout : Int32
          getter limit : Int64
          getter redirects : Int32
          getter? stream : Bool

          def initialize(@method, @headers, @body, @timeout, @limit, @redirects, @stream)
          end

          # `self` for a hop to `origin`; for a hop anywhere else, a copy
          # keeping only the headers `keep` names, lowercase.
          def for_hop(target : Target, origin : Target, keep : Set(String)) : Options
            return self if target.same_origin?(origin)
            kept = @headers.select { |name, _| keep.includes?(name.downcase) }
            Options.new(@method, kept, @body, @timeout, @limit, @redirects, @stream)
          end

          # Whether the request carries a body, which decides the
          # redirect rule. An empty String counts as none.
          def payload? : Bool
            body = @body
            return false unless body
            !body.empty?
          end

          def self.read(ncc : NativeCallContext, broker : Broker, transport : RubyClass) : Options
            stream = Helpers.checked_bool_kwarg(ncc, "Legate.fetch", "stream") || false

            method = Helpers.checked_symbol_kwarg(ncc, "Legate.fetch", "method")
            timeout = Helpers.checked_int_kwarg(ncc, "Legate.fetch", "timeout")
            redirects = Helpers.checked_int_kwarg(ncc, "Legate.fetch", "redirects")
            limit = Helpers.checked_int_kwarg(ncc, "Legate.fetch", "limit")

            # A streamed response is clamped to `stream_limit` (a
            # runaway guard), a buffered one to `fetch_limit` (a memory
            # cap).
            policy_limit = stream ? broker.grants.limits.stream_limit : broker.grants.limits.fetch_limit
            effective_limit = limit ? Math.min(limit, policy_limit) : policy_limit

            new(
              method: method ? method.name.downcase : DEFAULT_METHOD,
              headers: headers_of(ncc),
              body: body_of(ncc),
              timeout: timeout ? timeout.to_i32 : DEFAULT_TIMEOUT,
              limit: effective_limit,
              redirects: redirects ? redirects.to_i32 : DEFAULT_REDIRECTS,
              stream: stream,
            )
          end

          # A Hash of String to String. Other types raise R036 rather
          # than being stringified onto the wire.
          private def self.headers_of(ncc : NativeCallContext) : Hash(String, String)
            given = ncc.kwargs.try(&.["headers"]?)
            return {} of String => String unless given

            hash = given.as_hash?
            unless hash
              Helpers.raise_kwarg_type_error(ncc, "Legate.fetch", "headers", "Hash", given)
            end

            out = {} of String => String
            hash.each do |key, value|
              unless key.string? && value.string?
                Helpers.raise_kwarg_type_error(ncc, "Legate.fetch", "headers", "Hash of String => String", given)
              end
              out[key.as_string] = value.as_string
            end
            out
          end

          # A String, or an Array of Strings joined into one: the
          # request body isn't streamed.
          private def self.body_of(ncc : NativeCallContext) : String?
            given = ncc.kwargs.try(&.["body"]?)
            return unless given
            return if given.raw.nil?
            return given.as_string if given.string?

            if arr = given.as_array?
              pieces = arr.to_a.map do |piece|
                unless piece.string?
                  Helpers.raise_kwarg_type_error(ncc, "Legate.fetch", "body", "String or Array of String", given)
                end
                piece.as_string
              end
              return pieces.join
            end

            Helpers.raise_kwarg_type_error(ncc, "Legate.fetch", "body", "String or Array of String", given)
          end
        end

        # One hop's destination, with scheme, host and port checked
        # and non-nil.
        struct Target
          getter uri : URI
          getter scheme : String
          getter host : String
          getter port : Int32

          def initialize(@uri, @scheme, @host, @port)
          end

          # Same scheme, host and port. The scheme is already
          # downcased; host names are case-insensitive.
          def same_origin?(other : Target) : Bool
            @scheme == other.scheme && @host.downcase == other.host.downcase && @port == other.port
          end
        end

        private def self.parse_uri(url : String, ncc : NativeCallContext, transport : RubyClass) : Target
          uri = begin
            URI.parse(url)
          rescue
            ncc.raise_error_class("Legate.fetch — #{url.inspect} is not a valid URL", transport)
          end

          # Each nil check is its own statement, since Crystal doesn't
          # narrow a nilable local through a compound condition.
          raw_scheme = uri.scheme
          if raw_scheme.nil?
            ncc.raise_error_class("Legate.fetch — #{url.inspect} has no scheme; an http or https URL is required", transport)
          end

          scheme = raw_scheme.downcase
          unless scheme == "http" || scheme == "https"
            ncc.raise_error_class("Legate.fetch — #{url.inspect} must be an http or https URL", transport)
          end

          host = uri.host
          if host.nil?
            ncc.raise_error_class("Legate.fetch — #{url.inspect} has no host", transport)
          end
          if host.empty?
            ncc.raise_error_class("Legate.fetch — #{url.inspect} has no host", transport)
          end

          Target.new(uri, scheme, host, uri.port || NetRule::DEFAULT_PORTS[scheme])
        end

        # Resolves the hostname to every address (§8.2), so a benign A
        # record can't hide a hostile AAAA. A class property, so specs
        # can install a fixed answer: DNS happens before
        # `HTTP::Client`, which the replay harness intercepts.
        class_property resolver : Proc(String, Int32, Array(Socket::IPAddress)) = ->(host : String, port : Int32) {
          Socket::Addrinfo.tcp(host, port).map(&.ip_address)
        }

        private def self.resolve(host : String, port : Int32, ncc : NativeCallContext,
                                 transport : RubyClass) : Array(Socket::IPAddress)
          resolver.call(host, port)
        rescue ex : Socket::Error
          ncc.raise_error_class("Legate.fetch — could not resolve #{host}: #{ex.message}", transport)
        end

        # How §8.2 treats an address, ordered so the most restrictive
        # of several answers is the `max`.
        enum Reach
          Public  # allowed
          Local   # refused unless the matched rule sets `local: true`
          Blocked # refused regardless of any rule
        end

        # Refuses the hop unless every address passes (§8.2). Metadata,
        # link-local, multicast, broadcast and reserved ranges are
        # always refused; loopback and private space only when the
        # matched rule lacks `local: true`. The ranges are written out
        # rather than taken from `Socket::IPAddress`'s predicates,
        # whose exact coverage varies.
        private def self.check_addresses!(addresses : Array(Socket::IPAddress), host : String,
                                          allow_local : Bool, ncc : NativeCallContext,
                                          transport : RubyClass) : Nil
          if addresses.empty?
            ncc.raise_error_class("Legate.fetch — #{host} resolved to no addresses", transport)
          end

          addresses.each do |address|
            case reach(address.address)
            in .blocked?
              ncc.raise_error_class(
                "Legate.fetch — #{host} resolves to #{address.address}, which is in a link-local, metadata, multicast or reserved range",
                transport,
              )
            in .local?
              next if allow_local
              # Names the remedy: `local: true` is the one refusal a
              # policy may overturn.
              ncc.raise_error_class(
                "Legate.fetch — #{host} resolves to #{address.address}, which is loopback or private space; the matching net rule needs local: true",
                transport,
              )
            in .public?
              next
            end
          end
        end

        # An address's `Reach`, from its text. Text that parses as
        # neither IPv4 nor IPv6 is `Blocked`.
        private def self.reach(text : String) : Reach
          if octets = dotted_quad(text)
            return reach_ipv4(octets)
          end
          fields = Socket::IPAddress.parse_v6_fields?(text)
          return Reach::Blocked unless fields
          reach_ipv6(fields.to_a.map(&.to_i32))
        end

        private def self.dotted_quad(text : String) : Array(Int32)?
          parts = text.split('.')
          return unless parts.size == 4

          octets = [] of Int32
          parts.each do |part|
            value = part.to_i32?
            return unless value
            return if value < 0 || value > 255
            octets << value
          end
          octets
        end

        # IPv4 ranges that aren't `Public`, as network, prefix length
        # and reach. Where ranges overlap, the most restrictive wins.
        IPV4_RANGES = [
          {[0, 0, 0, 0], 8, Reach::Blocked},          # "this network"
          {[169, 254, 0, 0], 16, Reach::Blocked},     # link-local, incl. the 169.254.169.254 metadata endpoint
          {[100, 100, 100, 200], 32, Reach::Blocked}, # Alibaba Cloud metadata, inside carrier-grade NAT
          {[192, 0, 0, 0], 24, Reach::Blocked},       # IETF protocol assignments
          {[198, 18, 0, 0], 15, Reach::Blocked},      # benchmarking
          {[224, 0, 0, 0], 3, Reach::Blocked},        # multicast, reserved, broadcast
          {[127, 0, 0, 0], 8, Reach::Local},          # loopback
          {[10, 0, 0, 0], 8, Reach::Local},           # private
          {[172, 16, 0, 0], 12, Reach::Local},        # private
          {[192, 168, 0, 0], 16, Reach::Local},       # private
          {[100, 64, 0, 0], 10, Reach::Local},        # carrier-grade NAT
        ]

        private def self.reach_ipv4(o : Array(Int32)) : Reach
          address = ipv4_value(o)
          matches = IPV4_RANGES.select do |network, bits, _|
            mask = ~0_u32 << (32 - bits)
            (address & mask) == (ipv4_value(network) & mask)
          end
          matches.max_of?(&.[2]) || Reach::Public
        end

        # The four octets as one 32-bit value, first octet highest.
        private def self.ipv4_value(o : Array(Int32)) : UInt32
          o.reduce(0_u32) { |acc, octet| (acc << 8) | octet.to_u32 }
        end

        IPV6_UNSPECIFIED = [0, 0, 0, 0, 0, 0, 0, 0]
        IPV6_LOOPBACK    = [0, 0, 0, 0, 0, 0, 0, 1]
        # AWS's IPv6 metadata endpoint, `fd00:ec2::254`.
        AWS_METADATA_IPV6 = [0xfd00, 0xec2, 0, 0, 0, 0, 0, 0x254]

        # IPv6 prefixes that aren't `Public`, as the first field's
        # value, its mask and the reach.
        IPV6_PREFIXES = [
          {0xFE80, 0xFFC0, Reach::Blocked}, # fe80::/10, link-local
          {0xFF00, 0xFF00, Reach::Blocked}, # ff00::/8, multicast
          {0xFC00, 0xFE00, Reach::Local},   # fc00::/7, unique-local
        ]

        # Where the IPv4 address sits, as byte indexes, for each prefix
        # length RFC 6052 allows under `64:ff9b:1::/48`. Byte 8 is
        # reserved and never holds address bits.
        LOCAL_NAT64_LAYOUTS = [
          [6, 7, 9, 10],    # /48
          [7, 9, 10, 11],   # /56
          [9, 10, 11, 12],  # /64
          [12, 13, 14, 15], # /96
        ]

        # `f` is the eight 16-bit fields.
        private def self.reach_ipv6(f : Array(Int32)) : Reach
          return Reach::Blocked if f == IPV6_UNSPECIFIED || f == AWS_METADATA_IPV6
          return Reach::Local if f == IPV6_LOOPBACK
          if reach = embedded_reach(f)
            return reach
          end
          matches = IPV6_PREFIXES.select { |prefix, mask, _| (f[0] & mask) == prefix }
          matches.max_of?(&.[2]) || Reach::Public
        end

        # An IPv6 address that carries an IPv4 one (mapped, compatible
        # or NAT64) is judged as that IPv4 address, since that is where
        # the packets go; nil for any other. Check `::` and `::1` first,
        # which are in the compatible range.
        private def self.embedded_reach(f : Array(Int32)) : Reach?
          bytes = f.flat_map { |field| [field >> 8, field & 0xFF] }
          last_four = bytes[12, 4]

          # ::ffff:0:0/96 (mapped) and ::/96 (compatible).
          return reach_ipv4(last_four) if f[0, 5].all?(&.zero?) && (f[5] == 0xFFFF || f[5] == 0)

          return unless f[0] == 0x64 && f[1] == 0xFF9B
          # 64:ff9b::/96, the well-known NAT64 prefix.
          return reach_ipv4(last_four) if f[2, 4].all?(&.zero?)
          return unless f[2] == 1
          # 64:ff9b:1::/48, for local use: the operator picks the prefix
          # length, so every layout is judged, and the range itself is
          # local.
          candidates = LOCAL_NAT64_LAYOUTS.map { |layout| reach_ipv4(layout.map { |i| bytes[i] }) }
          (candidates << Reach::Local).max
        end

        # One buffered request through `HTTP::Client#exec`, the seam the
        # replay harness intercepts, reading the body in pieces so
        # `limit` applies as bytes arrive.
        private def self.perform(target : Target, pinned : Socket::IPAddress, opts : Options,
                                 ncc : NativeCallContext, transport : RubyClass, timeout_cls : RubyClass,
                                 too_large : RubyClass, broker : Broker) : Result
          uri = target.uri
          # An explicit TLS context, which the pinning override
          # needs. It verifies the certificate and hostname, and
          # nothing lets a script weaken that (§8.2).
          tls = target.scheme == "https" ? OpenSSL::SSL::Context::Client.new : nil
          client = HTTP::Client.new(target.host, target.port, tls: tls)
          # Pins the connection (§8.2); see http_client_pinning.cr.
          client.adjutant_pinned_address = pinned.address
          # `timeout:` is Integer seconds at the script boundary.
          client.connect_timeout = opts.timeout.seconds
          client.read_timeout = opts.timeout.seconds

          request_headers = HTTP::Headers.new
          opts.headers.each { |name, value| request_headers[name] = value }

          request = HTTP::Request.new(opts.method.upcase, request_target(uri), request_headers, opts.body)

          # Captured into a local: the `exec` block's value doesn't
          # type as the method's return. Everything needed later is
          # copied out inside the block.
          result : Result? = nil

          begin
            client.exec(request) do |response|
              body = read_body(response, opts.limit, ncc, too_large, broker)
              headers = {} of String => String
              response.headers.each { |key, values| headers[key] = values.join(", ") }
              result = Result.new(response.status_code, headers, body)
            end
          rescue IO::TimeoutError
            ncc.raise_error_class("Legate.fetch — timed out after #{opts.timeout}s fetching #{uri}", timeout_cls)
          rescue ex : Socket::Error | OpenSSL::Error | IO::Error
            ncc.raise_error_class("Legate.fetch — transport failure fetching #{uri}: #{ex.message}", transport)
          ensure
            client.close
          end

          # Copied from the closured variable, which Crystal won't
          # narrow, so the nil check below applies.
          captured = result
          return captured if captured

          ncc.raise_error_class("Legate.fetch — no response received from #{uri}", transport)
        end

        # Path and query only, so the connection's host and port are
        # exactly the authorized ones.
        private def self.request_target(uri : URI) : String
          path = uri.path
          path = "/" if path.nil? || path.empty?
          query = uri.query
          query && !query.empty? ? "#{path}?#{query}" : path
        end

        # Reads the body, enforcing `limit` and recording each chunk
        # against the read budget as it arrives.
        private def self.read_body(response, limit : Int64, ncc : NativeCallContext,
                                   too_large : RubyClass, broker : Broker) : String
          io = response.body_io?
          return response.body || "" unless io

          buffer = IO::Memory.new
          chunk = ::Bytes.new(READ_CHUNK_SIZE)
          total = 0_i64
          loop do
            n = io.read(chunk)
            break if n == 0
            total += n
            if total > limit
              ncc.raise_error_class("Legate.fetch — response exceeded the #{limit}-byte limit", too_large)
            end
            broker.budget.record_read(n.to_i64)
            buffer.write(chunk[0, n])
          end
          buffer.to_s
        end

        # The `Location` of a redirect status. 304 isn't a redirect.
        private def self.redirect_target(result : Result) : String?
          redirect_target_of(result.status_code, result.headers)
        end

        # `redirect_target` for the streaming path's status and
        # headers.
        private def self.redirect_target_of(status : Int32, headers : Hash(String, String)) : String?
          return unless {301, 302, 303, 307, 308}.includes?(status)
          location = headers["location"]? || headers["Location"]?
          location && !location.empty? ? location : nil
        end

        # Raises `Legate::Redirect` for a redirected request with a
        # body.
        private def self.raise_payload_redirect(ncc : NativeCallContext, redirect : RubyClass,
                                                status : Int32, location : String,
                                                label : RiskFlowLabel?) : NoReturn
          ncc.raise_error_class(
            "Legate.fetch — #{status} redirect to #{location} on a request with a body; " \
            "re-issue it yourself if you mean to send the body there",
            redirect,
            {"status"   => Value.int(status.to_i64),
             "location" => Value.string(location, label)},
          )
        end

        # Opens one hop without reading its body. The connection passes
        # to the returned StreamedResponse, then to the hop loop, which
        # closes it on a redirect, or to ResponseChunkIterator, which
        # closes it at exhaustion and is registered for teardown.
        private def self.perform_streaming(target : Target, pinned : Socket::IPAddress, opts : Options,
                                           ncc : NativeCallContext, transport : RubyClass,
                                           timeout_cls : RubyClass) : StreamedResponse
          uri = target.uri
          tls = target.scheme == "https" ? OpenSSL::SSL::Context::Client.new : nil
          client = HTTP::Client.new(target.host, target.port, tls: tls)
          client.adjutant_pinned_address = pinned.address
          client.connect_timeout = opts.timeout.seconds
          # `HttpResponseStream` has no timeout of its own, so a server
          # stalling mid-body would otherwise block forever.
          client.read_timeout = opts.timeout.seconds

          request_headers = HTTP::Headers.new
          opts.headers.each { |name, value| request_headers[name] = value }
          request = HTTP::Request.new(opts.method.upcase, request_target(uri), request_headers, opts.body)

          begin
            StreamedResponse.new(Utils::HttpResponseStream.open(client, request, READ_CHUNK_SIZE))
          rescue IO::TimeoutError
            ncc.raise_error_class("Legate.fetch — timed out after #{opts.timeout}s fetching #{uri}", timeout_cls)
          rescue ex : Socket::Error | OpenSSL::Error | IO::Error
            ncc.raise_error_class("Legate.fetch — transport failure fetching #{uri}: #{ex.message}", transport)
          end
        end

        # `location` resolved against the hop it came from, so the
        # next hop authorizes a complete URL.
        private def self.absolutize(location : String, base : URI) : String
          base.resolve(location).to_s
        rescue
          location
        end

        # One hop's outcome, copied out of the `exec` block, outside
        # which its response is invalid.
        struct Result
          getter status_code : Int32
          getter headers : Hash(String, String)
          getter body : String

          def initialize(@status_code, @headers, @body)
          end
        end

        # One hop opened but not read, with headers as
        # `Hash(String, String)`.
        class StreamedResponse
          # Declared: Crystal can't infer an ivar set only by `||=`.
          @header_hash : Hash(String, String)?

          def initialize(@stream : Utils::HttpResponseStream)
          end

          def status : Int32
            @stream.status
          end

          def headers : Hash(String, String)
            @header_hash ||= begin
              out = {} of String => String
              @stream.headers.each { |key, values| out[key] = values.join(", ") }
              out
            end
          end

          # The same as `headers`.
          def header_hash : Hash(String, String)
            headers
          end

          def next_chunk : ::Bytes?
            @stream.next_chunk
          end

          def close : Nil
            @stream.close
          end
        end

        # A stream over a response body: owns the connection for one
        # walk, closes it at exhaustion, and is registered for
        # teardown, as `Legate.bytes`' iterator is for a file.
        class ResponseChunkIterator
          include ::Iterator(Value)
          include Closable

          def initialize(@response : StreamedResponse, @limit : Int64, @chunk_cls : RubyClass,
                         @label : RiskFlowLabel?, @broker : Broker, @ncc : NativeCallContext,
                         @too_large : RubyClass)
            @done = false
            @total = 0_i64
          end

          def next
            return stop if @done

            chunk = @response.next_chunk
            unless chunk
              close_source
              return stop
            end

            @total += chunk.size
            # `stream_limit` is enforced as bytes arrive. The connection
            # is closed before raising, so a script that rescues isn't
            # left holding it.
            if @total > @limit
              close_source
              @ncc.raise_error_class("Legate.fetch — response exceeded the #{@limit}-byte limit", @too_large)
            end

            @broker.budget.record_read(chunk.size.to_i64)
            Legate::Chunk.build(@chunk_cls, chunk, @label)
          end

          # Idempotent: reached at exhaustion, on a limit breach, and at
          # teardown.
          def close_source : Nil
            return if @done
            @done = true
            @response.close
            @broker.open_sources.release(self)
          end
        end
      end
    end
  end
end
