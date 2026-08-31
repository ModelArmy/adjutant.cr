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
      # limit:, redirects:) -> Legate::Response` — LEGATE.md §4.5.
      #
      # The boundary §4.5 insists on, and the thing most likely to be
      # got wrong by anyone extending this file: **transport failures
      # raise; HTTP status codes do not.** A 500 is an answer. A DNS
      # failure is not. Nothing below ever turns a status code into an
      # exception — `Legate::Response#raise!` exists precisely so a
      # script can opt into that itself.
      #
      # `stream: true` (§4.5) hands back a `Legate::Bytes` whose
      # iterator owns the connection for the life of the walk, rather
      # than a buffered String. The mechanism is worth knowing before
      # reading the hop loop: Crystal's non-block `HTTP::Client#exec`
      # buffers the whole body, and its block form closes the
      # connection when the block returns, so NEITHER form can hand
      # back a body that outlives the call. `Utils::HttpResponseStream`
      # bridges that — it keeps the block open on its own fiber and
      # hands chunks across a channel — and this verb layers the
      # Legate concerns (label, budget, `stream_limit`, the open-source
      # registry) on top of it.
      #
      # STILL BUFFERED: an Enumerable `body:`, which is joined into one
      # String before the request is built. Logged in SCOPE.md.
      #
      # PINNING (§8.2), implemented in `http_client_pinning.cr`. §8.2
      # requires three things of every hop: resolve the hostname,
      # check EVERY resulting address against the private/loopback/
      # link-local/metadata ranges, then pin the chosen address for
      # the connection. All three happen — see that file for how the
      # third is done without disturbing TLS hostname
      # verification, the `Host` header, or the laziness that lets
      # replayed specs run without opening a socket.
      #
      module Fetch
        KWARG_NAMES = Set{"method", "headers", "body", "stream", "timeout", "limit", "redirects"}

        DEFAULT_METHOD    = "get"
        DEFAULT_TIMEOUT   = 30
        DEFAULT_REDIRECTS =  5

        # Read in pieces so `limit` is enforced AS BYTES ARRIVE (§8.2),
        # not after a full buffer exists — the difference between
        # refusing a 4 GiB response and allocating one first. Matches
        # `bytes.cr`/`cp.cr`'s own chunk size for the same reason.
        READ_CHUNK_SIZE = 65_536

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          transport = Helpers.fetch(legate, interp, "Transport")
          timeout_cls = Helpers.fetch(legate, interp, "Timeout")
          too_large = Helpers.fetch(legate, interp, "TooLarge")
          redirect = Helpers.fetch(legate, interp, "Redirect")
          too_many = Helpers.fetch(legate, interp, "TooMany")
          response_cls = Helpers.fetch(legate, interp, "Response")
          # `stream: true` hands back the same `Legate::Bytes` a
          # `Legate.bytes` call does — §3's type index has one stream
          # type, not one per source — so the classes come from the
          # same place rather than fetch growing its own.
          bytes_cls = Helpers.fetch(legate, interp, "Bytes")
          chunk_cls = Helpers.fetch(legate, interp, "Chunk")

          legate.define_native_singleton_method(
            interp.symbols.intern("fetch").value,
            RiskProfile.new(
              tags: Set{RiskTag::NetworkEgress},
              # Egress is not undoable — once bytes leave the process
              # no policy decision can call them back. Same reasoning
              # `rm.cr` gives for being the first verb to set these at
              # all rather than accepting the `Yes`/`Info` defaults.
              reversible: Reversibility::No,
              severity: Severity::Warning,
            ),
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            # Convention 1: every kwarg validated BEFORE any
            # authorize_* call, so a wrong-typed kwarg never consumes
            # an audit-log entry for a call that fails regardless.
            opts = Options.read(ncc, broker, transport)

            url_val = args[1]? || Value.nil_value
            url_str_val = ncc.call_method(url_val, "to_s", [] of Value)
            raw_url = url_str_val.as_string
            label = url_str_val.label

            # The URL-length cap, checked BEFORE authorization on
            # purpose — an over-long URL is never authorized, never
            # resolved, and never audited as allowed egress. See
            # `Limits::DEFAULT_URL_LIMIT`'s own comment for why the
            # request side needs a cap at all: `fetch_limit` bounds
            # the RESPONSE, leaving the query string as an
            # unmetered exfiltration channel.
            url_limit = broker.grants.limits.url_limit
            if raw_url.bytesize > url_limit
              ncc.raise_error_class("Legate.fetch — URL is #{raw_url.bytesize} bytes, over the #{url_limit}-byte url_limit", too_large)
            end

            current_url = raw_url
            hops = 0

            loop do
              target = parse_uri(current_url, ncc, transport)
              scheme = target.scheme
              host = target.host
              port = target.port

              # Re-run per hop, deliberately — §8.2's "a permitted
              # host that 302s to 169.254.169.254 is the standard
              # SSRF." A redirect to a host outside the allowlist is
              # a FATAL `Legate::Denied`, same as any other grant
              # denial: the embedder's call, on the reasoning that
              # it is easier to relax this later than to tighten it
              # once scripts depend on catching it.
              label = RiskFlowLabel.join(label, broker.authorize_net(scheme, host, port, opts.method, ncc))

              addresses = resolve(host, port, ncc, transport)
              allow_local = broker.net_allows_local?(scheme, host, port, opts.method)
              check_addresses!(addresses, host, allow_local, ncc, transport)

              # Pin the FIRST vetted address. Which one hardly matters
              # — `check_addresses!` refuses the whole hop unless
              # EVERY address passed, so there is no "safest" entry to
              # prefer — but pinning one specific address is the whole
              # point, so it is chosen here, once, and carried into
              # the connection rather than left to the TCP stack to
              # pick again later.
              # STREAMING AND BUFFERED SHARE THIS LOOP, and the
              # streaming half deliberately runs every hop through
              # `HttpResponseStream` too, not just the last one.
              #
              # It has to: whether a hop is the last one is decided by
              # its own status and `Location`, which are not known
              # until the response has been opened. `HttpResponseStream`
              # exposes both BEFORE any body byte is pulled, which is
              # exactly what makes "open it, look, then either close
              # and follow or keep it" possible. An intermediate hop
              # is closed unread — its body is a redirect notice
              # nobody wants — and only the final one is kept and
              # handed to the script.
              if opts.stream?
                # BEFORE the connection is opened, so a refusal at the
                # cap leaves nothing to leak — the same ordering
                # `bytes.cr` uses around `File.open`, and the reason
                # the check is separate from registration at all.
                broker.check_stream_capacity!(ncc, too_many)

                streamed = perform_streaming(target, addresses.first, opts, ncc, transport, timeout_cls)
                location = redirect_target_of(streamed.status, streamed.headers)

                if location
                  # Every path below abandons this hop, so the
                  # connection goes back before anything can raise —
                  # an `ensure` would be wrong here, since the
                  # SUCCESS path must NOT close it.
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

              # THE PAYLOAD RULE (§4.5). A redirect on a request that
              # carried a body is handed back to the script; a
              # body-less request is followed automatically, as before.
              #
              # Neither half of what a client would otherwise do is
              # safe to do silently once a body is involved:
              #
              #   - 307/308 mean "replay this exactly." Re-sending a
              #     body the script may have streamed is impossible
              #     (a Legate stream is single-pass, §6.1) and
              #     re-sending it to a DIFFERENT host is a second full
              #     upload the script never asked for.
              #   - 301/302/303 are, by three decades of practice,
              #     degraded to GET with the body dropped. A POST
              #     silently becomes a GET, the request the script
              #     asked for never happens, and the script gets a 200
              #     for it. That is the worse failure of the two: it
              #     looks like success.
              #
              # A single rule covering all five rather than a
              # per-status table, deliberately. The two-clause version
              # ("must replay and cannot" or "would be downgraded")
              # predicts the same outcomes but asks a reader to hold
              # four status codes and their history in mind; a script
              # author only has to know "I sent information, so I own
              # what happens to it." The 303 case genuinely costs one
              # extra explicit `Legate.fetch` for the receipt, and that
              # is the accepted price of the simpler rule — `status` is
              # on the error precisely so a script that wants to
              # auto-follow one code can, in a line.
              #
              # Keys on THE BODY, NOT THE METHOD: a POST with no body
              # follows redirects, a PUT with one does not. A method
              # table would drift from reality the way the status table
              # just did.
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

        # Every kwarg, read and type-checked in one place so the verb
        # body above stays readable. `limit` is CLAMPED to the
        # policy's own `fetch_limit` and can never exceed it — a
        # script asking for a larger cap than policy allows gets
        # policy's, silently, exactly as `read.cr` already does with
        # `read_limit`. Asking for a SMALLER one is honoured.
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

          # Whether this request carried something the script sent —
          # the trigger for the redirect rule in the hop loop above.
          #
          # An EMPTY String counts as no payload. Raising on a
          # zero-length body would be pedantry: nothing is at stake,
          # there is nothing to replay and nothing to silently drop.
          # The choice is arbitrary enough to be worth stating rather
          # than leaving a reader to infer it from the `.empty?`.
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

            # WHICH policy cap `limit` is clamped against depends on
            # `stream:`, because the two caps answer different
            # questions — `fetch_limit` is how much this run will hold
            # in memory at once, `stream_limit` is how far a response
            # may run before it is treated as endless. See
            # `Limits::DEFAULT_STREAM_LIMIT`. Clamping a streamed
            # response against `fetch_limit` would make `stream: true`
            # useless for exactly the bodies it exists for.
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

          # `headers:` is a Hash of String => String. Both halves are
          # checked rather than `to_s`-coerced: a header whose value
          # came from an unexpected type is far more likely to be a
          # bug at the call site than an intentional conversion, and
          # silently stringifying it would put whatever
          # `inspect`-ish text resulted onto the wire.
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

          # §4.5: "`body:` accepts a String or an Enumerable, so
          # uploads stream." An Array is materialised into one String
          # here rather than genuinely streamed — the same staging
          # decision `stream:` gets above, and for a related reason
          # (a streaming request body needs the connection's own IO,
          # which the buffered path doesn't expose). A String body is
          # the common case and is passed through untouched.
          private def self.body_of(ncc : NativeCallContext) : String?
            given = ncc.kwargs.try(&.["body"]?)
            return nil unless given
            return nil if given.raw.nil?
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

        # One hop's destination, with scheme/host/port already
        # validated and made concrete. Returning this rather than a
        # bare `URI` is what keeps the hop loop free of `not_nil!`:
        # `URI#scheme` and `#host` are both nilable, and every caller
        # downstream needs them proven present anyway, so proving it
        # once here and carrying the result is both safer and
        # shorter than re-asserting it at each use.
        struct Target
          getter uri : URI
          getter scheme : String
          getter host : String
          getter port : Int32

          def initialize(@uri, @scheme, @host, @port)
          end
        end

        private def self.parse_uri(url : String, ncc : NativeCallContext, transport : RubyClass) : Target
          uri = begin
            URI.parse(url)
          rescue
            ncc.raise_error_class("Legate.fetch — #{url.inspect} is not a valid URL", transport)
          end

          # Nil is guarded on its OWN line for both of these, rather
          # than folded into the validity check with `||`. Crystal
          # narrows a nilable local after a nil test whose branch
          # can't fall through — but not through a compound condition
          # — so `unless scheme == "http" || ...` leaves `scheme` a
          # `String?` no matter that the failing branch raises. Two
          # statements, and `Target` gets the concrete Strings it
          # asks for without a `not_nil!` anywhere.
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

        # §8.2 step one: resolve the hostname to EVERY address, not
        # just the first. A host whose A record is benign and whose
        # AAAA record points at the metadata service must be refused,
        # so all of them are checked below.
        #
        # Indirected through `resolver` rather than calling
        # `Socket::Addrinfo` directly, for a reason that only shows up
        # once these specs run offline: a record/replay harness
        # intercepts `HTTP::Client`, so a replayed request never
        # touches the network — but this DNS lookup happens BEFORE the
        # client is involved and would still hit a real resolver,
        # making an otherwise-offline CI run depend on DNS for a host
        # it never actually contacts. The seam lets a spec install a
        # fixed answer. It is a class property rather than a
        # constructor argument because `Fetch` is a module of
        # singleton methods like every other verb here, and threading
        # a resolver through the broker for one verb's benefit would
        # be a far larger change than the problem warrants.
        class_property resolver : Proc(String, Int32, Array(Socket::IPAddress)) = ->(host : String, port : Int32) {
          Socket::Addrinfo.tcp(host, port).map(&.ip_address)
        }

        private def self.resolve(host : String, port : Int32, ncc : NativeCallContext,
                                 transport : RubyClass) : Array(Socket::IPAddress)
          resolver.call(host, port)
        rescue ex : Socket::Error
          ncc.raise_error_class("Legate.fetch — could not resolve #{host}: #{ex.message}", transport)
        end

        # §8.2 step two, split across two questions rather than one.
        #
        # Some ranges are refused NO MATTER WHAT a policy says: the
        # cloud metadata endpoint and its link-local neighbours,
        # multicast, broadcast, and the various reserved blocks. No
        # script has a legitimate reason to reach any of them, and
        # `169.254.169.254` in particular is the highest-value SSRF
        # target there is.
        #
        # Loopback and private space are different. §8.2's
        # confused-deputy problem is a script reaching an internal
        # address it never NAMED — a permitted public host that 302s
        # somewhere private. A policy that names `localhost:11434`
        # itself is not confused, and refusing it would rule out an
        # entire category of legitimate use (a local model server, a
        # service on the LAN, a dev backend). So those ranges are
        # gated on the matched rule's `local: true`, resolved per hop
        # by `Grants#net_allows_local?`.
        #
        # Deliberately hand-rolled octet arithmetic rather than
        # `Socket::IPAddress`'s own `#private?`/`#loopback?`/
        # `#link_local?` predicates: those exist in recent Crystal,
        # but their exact coverage (does `private?` include
        # carrier-grade NAT? does `link_local?` cover IPv6 fe80::/10?)
        # is precisely the sort of thing this check cannot afford to
        # be approximately right about, and the ranges below are short
        # enough to state outright and read.
        private def self.check_addresses!(addresses : Array(Socket::IPAddress), host : String,
                                          allow_local : Bool, ncc : NativeCallContext,
                                          transport : RubyClass) : Nil
          if addresses.empty?
            ncc.raise_error_class("Legate.fetch — #{host} resolved to no addresses", transport)
          end

          addresses.each do |address|
            if always_blocked?(address)
              ncc.raise_error_class(
                "Legate.fetch — #{host} resolves to #{address.address}, which is in a link-local, metadata, multicast or reserved range",
                transport,
              )
            end

            next unless local_range?(address)
            next if allow_local

            # The message names the remedy, because this is the one
            # denial in the whole check that a policy author is
            # entitled to overturn.
            ncc.raise_error_class(
              "Legate.fetch — #{host} resolves to #{address.address}, which is loopback or private space; the matching net rule needs local: true",
              transport,
            )
          end
        end

        # Refused regardless of any rule.
        private def self.always_blocked?(address : Socket::IPAddress) : Bool
          text = address.address.downcase
          if octets = ipv4_octets(text)
            return always_blocked_ipv4?(octets)
          end
          always_blocked_ipv6?(text)
        end

        # Refused unless the matched rule sets `local: true`.
        private def self.local_range?(address : Socket::IPAddress) : Bool
          text = address.address.downcase
          if octets = ipv4_octets(text)
            return local_ipv4?(octets)
          end
          local_ipv6?(text)
        end

        # Returns the four octets when `text` denotes an IPv4 address,
        # in any of the three spellings that can reach this point.
        # BOTH IPv4-mapped IPv6 forms are handled, since neither is a
        # bare dotted quad and as IPv6 strings they match none of the
        # prefixes checked elsewhere: the dotted spelling
        # (`::ffff:127.0.0.1`) is what a person would write, while the
        # hex spelling (`::ffff:7f00:1`) is what
        # `Socket::IPAddress#address` may render back — checking only
        # the first would leave the real one open.
        private def self.ipv4_octets(text : String) : Array(Int32)?
          if text.starts_with?("::ffff:")
            mapped = text.lchop("::ffff:")
            return dotted_quad(mapped) if mapped.includes?('.')
            return hex_pair_octets(mapped)
          end
          dotted_quad(text)
        end

        private def self.dotted_quad(text : String) : Array(Int32)?
          parts = text.split('.')
          return nil unless parts.size == 4

          octets = [] of Int32
          parts.each do |part|
            value = part.to_i32?
            return nil unless value
            return nil if value < 0 || value > 255
            octets << value
          end
          octets
        end

        # `7f00:1` -> [127, 0, 0, 1]. The two groups are 16 bits each,
        # high group first, and either may be written short.
        private def self.hex_pair_octets(text : String) : Array(Int32)?
          groups = text.split(':')
          return nil unless groups.size == 2
          high = groups[0].to_i32?(16)
          low = groups[1].to_i32?(16)
          return nil unless high && low
          return nil if high < 0 || high > 0xFFFF || low < 0 || low > 0xFFFF
          [(high >> 8) & 0xFF, high & 0xFF, (low >> 8) & 0xFF, low & 0xFF]
        end

        private def self.always_blocked_ipv4?(o : Array(Int32)) : Bool
          case
          when o[0] == 0                                 then true # 0.0.0.0/8 — "this network"
          when o[0] == 169 && o[1] == 254                then true # link-local, incl. the 169.254.169.254 metadata endpoint
          when o[0] == 192 && o[1] == 0 && o[2] == 0     then true # IETF protocol assignments
          when o[0] == 198 && (o[1] == 18 || o[1] == 19) then true # benchmarking
          when o[0] >= 224                               then true # multicast, reserved, broadcast
          else                                                false
          end
        end

        private def self.local_ipv4?(o : Array(Int32)) : Bool
          case
          when o[0] == 127                              then true # loopback
          when o[0] == 10                               then true # private
          when o[0] == 172 && o[1] >= 16 && o[1] <= 31  then true # private
          when o[0] == 192 && o[1] == 168               then true # private
          when o[0] == 100 && o[1] >= 64 && o[1] <= 127 then true # carrier-grade NAT
          else                                               false
          end
        end

        private def self.always_blocked_ipv6?(text : String) : Bool
          stripped = text.split('%').first # scope id, e.g. fe80::1%eth0
          return true if stripped == "::"
          return true if stripped.starts_with?("fe8") || stripped.starts_with?("fe9") ||
                         stripped.starts_with?("fea") || stripped.starts_with?("feb") # fe80::/10 link-local
          return true if stripped.starts_with?("ff")                                  # ff00::/8 multicast
          false
        end

        private def self.local_ipv6?(text : String) : Bool
          stripped = text.split('%').first
          return true if stripped == "::1"                           # loopback
          stripped.starts_with?("fc") || stripped.starts_with?("fd") # fc00::/7 unique-local
        end

        # One request, one response, fully buffered but read in
        # pieces so `limit` bites as bytes arrive. Goes through
        # `HTTP::Client#exec` — every other client method converges
        # there anyway, and it is the seam a record/replay harness
        # intercepts, so routing through it keeps these calls
        # testable without a live server.
        #
        # NOT independently verified against a live toolchain:
        # `HTTP::Client`'s timeout setters, `exec`'s block form
        # yielding a response whose `body_io` is readable, and the
        # exact exception types raised on connect/TLS failure are all
        # written from recollection. Same caveat this codebase flags
        # on every other stdlib assumption; the first `ops test` run
        # against a recorded transcript is what confirms them.
        private def self.perform(target : Target, pinned : Socket::IPAddress, opts : Options,
                                 ncc : NativeCallContext, transport : RubyClass, timeout_cls : RubyClass,
                                 too_large : RubyClass, broker : Broker) : Result
          uri = target.uri
          # An explicit context rather than `tls: true`, because
          # the pinning override needs the context object itself to hand to
          # `OpenSSL::SSL::Socket::Client`. The default client context
          # verifies the peer certificate and hostname; §8.2 makes
          # that non-configurable, so nothing here exposes a way to
          # weaken it — there is deliberately no `verify:` kwarg on
          # `Legate.fetch` for a script to reach for.
          tls = target.scheme == "https" ? OpenSSL::SSL::Context::Client.new : nil
          client = HTTP::Client.new(target.host, target.port, tls: tls)
          # THE pinning step (§8.2). Set on a plain `HTTP::Client`
          # rather than obtained by subclassing it — the receiver's
          # type has to stay exactly `HTTP::Client` or the
          # record/replay harness stops intercepting it. See
          # `http_client_pinning.cr`.
          client.adjutant_pinned_address = pinned.address
          # `Time::Span`, not a bare Int32 — the integer-seconds
          # setters are deprecated. `timeout:` stays an Integer at the
          # SCRIPT boundary (§4.5 spells it `timeout: 30`), so the
          # conversion belongs here, at the Crystal edge.
          client.connect_timeout = opts.timeout.seconds
          client.read_timeout = opts.timeout.seconds

          request_headers = HTTP::Headers.new
          opts.headers.each { |name, value| request_headers[name] = value }

          request = HTTP::Request.new(opts.method.upcase, request_target(uri), request_headers, opts.body)

          # The result is captured into a local rather than returned
          # straight out of `exec`'s block. The block form's own
          # return type isn't reliably the block's value here — the
          # compiler sees a `Result?` and rejects the method's
          # declared return type — and threading it through a local
          # is both the smaller change and the more explicit one:
          # everything needed after the connection closes is copied
          # out inside the block, which is the constraint that
          # actually matters (see `Result`'s own comment).
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

          # `result` is CLOSURED by the `exec` block above, and
          # Crystal does not narrow the type of a closured variable on
          # a truthiness check — every read of it stays `Result?` no
          # matter what has been tested. Copying it into an ordinary
          # local first is what makes the narrowing below actually
          # apply, and is why this is two statements rather than a
          # single `result || raise`.
          captured = result
          return captured if captured

          ncc.raise_error_class("Legate.fetch — no response received from #{uri}", transport)
        end

        # The origin-form request target — path plus query, never the
        # absolute URL. Building it here rather than handing
        # `HTTP::Client` the whole URI keeps the host/port the
        # connection actually uses identical to the ones just
        # authorized, with no second parse in between that could
        # disagree.
        private def self.request_target(uri : URI) : String
          path = uri.path
          path = "/" if path.nil? || path.empty?
          query = uri.query
          query && !query.empty? ? "#{path}?#{query}" : path
        end

        # `limit` enforced progressively (§8.2's "as bytes arrive, not
        # after"), and every chunk recorded against the read budget as
        # it lands — a large download can exhaust the per-run budget
        # partway through, matching every streaming verb already here.
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

        # Only the redirect statuses that carry a `Location`. A 304 is
        # deliberately absent: it is a cache answer, not a redirect,
        # and following it would be nonsense.
        private def self.redirect_target(result : Result) : String?
          redirect_target_of(result.status_code, result.headers)
        end

        # The same test against a status and headers that did not come
        # from a `Result` — the streaming path has both in hand before
        # any body exists, which is the whole reason it can decide
        # whether to keep a connection or drop it.
        private def self.redirect_target_of(status : Int32, headers : Hash(String, String)) : String?
          return nil unless {301, 302, 303, 307, 308}.includes?(status)
          location = headers["location"]? || headers["Location"]?
          location && !location.empty? ? location : nil
        end

        # Shared by the buffered and streaming paths so the rule is
        # stated once. See the hop loop for why it exists at all.
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

        # Opens one hop WITHOUT reading its body, handing back a live
        # connection the caller must eventually close.
        #
        # The client is deliberately NOT closed here and there is no
        # `ensure` doing it: ownership passes to the returned
        # `StreamedResponse`, and from there either to the hop loop
        # (which closes it on a redirect) or to
        # `ResponseChunkIterator` (which closes it on exhaustion, and
        # is registered with the run so teardown closes it otherwise).
        # This is the one place in the verb where a resource outlives
        # the method that made it, which is why the ownership chain is
        # spelled out rather than left to be traced.
        private def self.perform_streaming(target : Target, pinned : Socket::IPAddress, opts : Options,
                                           ncc : NativeCallContext, transport : RubyClass,
                                           timeout_cls : RubyClass) : StreamedResponse
          uri = target.uri
          tls = target.scheme == "https" ? OpenSSL::SSL::Context::Client.new : nil
          client = HTTP::Client.new(target.host, target.port, tls: tls)
          client.adjutant_pinned_address = pinned.address
          client.connect_timeout = opts.timeout.seconds
          # `HttpResponseStream` holds no timeouts of its own and
          # inherits this one — without it a server that stalls
          # mid-body parks the reader indefinitely. See that class's
          # own comment.
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

        # A `Location` may be relative; resolve it against the hop it
        # came from so the next iteration re-authorizes a complete,
        # absolute URL rather than a fragment with no host to check.
        private def self.absolutize(location : String, base : URI) : String
          base.resolve(location).to_s
        rescue
          location
        end

        # A plain carrier for one hop's outcome — the `exec` block
        # form's response object is only valid inside the block, so
        # everything needed afterwards is copied out before it
        # closes.
        struct Result
          getter status_code : Int32
          getter headers : Hash(String, String)
          getter body : String

          def initialize(@status_code, @headers, @body)
          end
        end

        # One hop opened but not read — status and headers available,
        # body still on the wire.
        #
        # A thin wrapper over `Utils::HttpResponseStream` rather than
        # the stream itself, purely so the rest of this verb speaks in
        # the same `Hash(String, String)` headers shape `Result` uses
        # and `Response.build` expects, instead of `HTTP::Headers`
        # leaking into the hop loop.
        class StreamedResponse
          # Declared rather than inferred: Crystal cannot type an ivar
          # that only ever appears under `||=`.
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

          # Same thing under the name the hop loop reads better with.
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

        # The response-side twin of `bytes.cr`'s `ChunkIterator`, and
        # deliberately the same shape: it owns a resource for the
        # lifetime of one walk, closes it on exhaustion, and registers
        # with the run so teardown closes it when the walk never
        # finishes. The resource is a socket rather than a file
        # handle, which changes nothing about the pattern and
        # everything about the cost of getting it wrong.
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
            # ENFORCED AS BYTES ARRIVE, matching the buffered path and
            # §8.2's own wording. The cap here is `stream_limit`, not
            # `fetch_limit` — a runaway guard rather than a memory one
            # (see `Limits::DEFAULT_STREAM_LIMIT`). The connection is
            # dropped before raising: a script that rescues this must
            # not be left holding an open socket to a server still
            # sending.
            if @total > @limit
              close_source
              @ncc.raise_error_class("Legate.fetch — response exceeded the #{@limit}-byte limit", @too_large)
            end

            @broker.budget.record_read(chunk.size.to_i64)
            Legate::Chunk.build(@chunk_cls, chunk, @label)
          end

          # Idempotent, as `Closable` requires — reachable from
          # exhaustion, from the limit breach above, and from run
          # teardown on a stream the script walked away from.
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
