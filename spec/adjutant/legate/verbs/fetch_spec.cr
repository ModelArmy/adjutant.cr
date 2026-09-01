require "../../../spec_helper"
require "socket"

# Every spec below that reaches the transport stage installs a fixed
# resolver, so nothing here depends on DNS. See `Fetch.resolver`'s own
# comment: a record/replay harness intercepts `HTTP::Client`, but the
# §8.2 address check runs BEFORE the client exists and would otherwise
# make an offline run depend on a real lookup for a host it never
# contacts.
private def with_resolver(addresses : Array(String), &)
  previous = Adjutant::Legate::Verbs::Fetch.resolver
  Adjutant::Legate::Verbs::Fetch.resolver = ->(_host : String, port : Int32) {
    addresses.map { |a| Socket::IPAddress.new(a, port) }
  }
  begin
    yield
  ensure
    Adjutant::Legate::Verbs::Fetch.resolver = previous
  end
end

# The resolver for the RECORDED specs, and the reason it isn't a fixed
# stub like `with_resolver` above.
#
# Since `Legate.fetch` pins the resolved address, a stubbed answer is
# no longer inert during recording — it is where the socket actually
# goes. A fixed placeholder would mean recording tries to reach
# `httpbin.org` at some unrelated host's address and fails, so those
# specs could never be re-recorded at all.
#
# So: resolve for real when the network is there (recording works, and
# the pinned address is genuinely httpbin's), and fall back to a fixed
# public placeholder when it isn't (replay works offline, and the
# address is never dialled because the harness answers first).
#
# `Legate.fetch` resolves on EVERY hop, including replayed ones — the
# address check runs before the client is involved — which is why some
# answer has to be available even when nothing will be connected to.
private def resolving_or_placeholder(&)
  previous = Adjutant::Legate::Verbs::Fetch.resolver
  Adjutant::Legate::Verbs::Fetch.resolver = ->(host : String, port : Int32) {
    begin
      Socket::Addrinfo.tcp(host, port).map(&.ip_address)
    rescue Socket::Error
      # 93.184.216.34 is a documented public address, chosen only
      # because it passes the §8.2 range checks. Nothing is ever
      # connected to it: reaching this branch means DNS is
      # unavailable, which means the run is offline, which means the
      # harness is replaying.
      [Socket::IPAddress.new("93.184.216.34", port)]
    end
  }
  begin
    yield
  ensure
    Adjutant::Legate::Verbs::Fetch.resolver = previous
  end
end

# Replay mode for the recorded specs below.
#
# `:none` rather than `:once`, deliberately. Under `:once` a
# transcript that fails to load — missing, misnamed, or no longer
# matching on URL or body digest — silently falls back to RECORDING,
# which means a real network call to whatever the resolver stub
# returned. That turns every kind of transcript problem into the same
# opaque connection error, and (worse) can quietly rewrite a committed
# transcript on a developer's machine.
#
# `:none` forbids recording, so a transcript problem fails loudly with
# a message naming the method, URL and digest it looked for.
#
# To RECORD — first time, or after deleting a transcript deliberately —
# run the suite once with WIRETAP_RECORD set:
#
#     WIRETAP_RECORD=1 crystal spec spec/adjutant/legate/verbs/fetch_spec.cr
#
# then commit the JSON under spec/transcripts/. Recording needs real
# network access and reaches the live host. Every other run, including
# CI, replays offline.
private RECORDED_MODE = ENV["WIRETAP_RECORD"]? ? :once : :none

module Adjutant
  private def self.net_grants(host : String = "api.example.com",
                              methods : Array(String) = ["get"]) : Legate::Grants
    Legate::Grants.new(net_rules: [Legate::NetRule.parse(host)], net_methods: methods)
  end

  describe "Legate.fetch" do
    # --- Checks that never reach the network at all ------------------

    describe "URL validation and the url_limit" do
      # Checked BEFORE authorization on purpose, so an over-long URL
      # is never authorized, resolved, or audited as allowed egress.
      it "raises Legate::TooLarge for a URL over the policy's url_limit" do
        grants = Legate::Grants.new(
          net_rules: [Legate::NetRule.parse("api.example.com")],
          net_methods: ["get"],
          limits: Legate::Limits.new(url_limit: 64_i64),
        )
        interp, _ = make_interp(grants: grants)
        long = "https://api.example.com/search?q=" + ("a" * 200)
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch(#{long.inspect})
          "no error"
        rescue Legate::TooLarge
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end

      it "consumes no audit record when the URL is over the limit" do
        grants = Legate::Grants.new(
          net_rules: [Legate::NetRule.parse("api.example.com")],
          net_methods: ["get"],
          limits: Legate::Limits.new(url_limit: 64_i64),
        )
        interp, _ = make_interp(grants: grants)
        long = "https://api.example.com/search?q=" + ("a" * 200)
        interp.eval(<<-RUBY)
        begin
          Legate.fetch(#{long.inspect})
        rescue Legate::TooLarge
        end
        RUBY
        interp.broker.audit_log.records.select { |r| r.verb == "net" }.size.should eq 0
      end

      it "raises Legate::Transport for a non-http scheme" do
        interp, _ = make_interp(grants: net_grants)
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch("ftp://api.example.com/x")
          "no error"
        rescue Legate::Transport
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end

      it "raises Legate::Transport for a URL with no host" do
        interp, _ = make_interp(grants: net_grants)
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch("/just/a/path")
          "no error"
        rescue Legate::Transport
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    describe "grant enforcement" do
      it "denies a host outside the allowlist, fatally" do
        interp, _ = make_interp(grants: net_grants)
        expect_raises(Legate::FatalSignal, /Legate\.net denied/) do
          interp.eval(%(Legate.fetch("https://evil.example.com/")))
        end
      end

      # The change NetRule exists for: an allowlisted NAME on an
      # unlisted port is a different service and is denied.
      it "denies an allowlisted host on a port the rule doesn't name" do
        interp, _ = make_interp(grants: net_grants)
        expect_raises(Legate::FatalSignal, /port 8443 is not in \[443\]/) do
          interp.eval(%(Legate.fetch("https://api.example.com:8443/")))
        end
      end

      it "denies plaintext http against an https-only rule" do
        interp, _ = make_interp(grants: net_grants)
        expect_raises(Legate::FatalSignal, /granted only over https/) do
          interp.eval(%(Legate.fetch("http://api.example.com/")))
        end
      end

      it "denies a method the policy doesn't grant" do
        interp, _ = make_interp(grants: net_grants(methods: ["get"]))
        expect_raises(Legate::FatalSignal, /method POST is not granted/) do
          interp.eval(%(Legate.fetch("https://api.example.com/", method: :post)))
        end
      end
    end

    # §8.2's SSRF hardening. These are the specs that matter most in
    # this file: a host the policy fully permits, whose NAME resolves
    # somewhere it must not be allowed to reach.
    describe "resolved-address checks (§8.2)" do
      it "refuses a permitted host that resolves to loopback" do
        with_resolver(["127.0.0.1"]) do
          interp, _ = make_interp(grants: net_grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("https://api.example.com/")
            "no error"
          rescue Legate::Transport
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      it "refuses the cloud metadata address specifically" do
        with_resolver(["169.254.169.254"]) do
          interp, _ = make_interp(grants: net_grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("https://api.example.com/")
            "no error"
          rescue Legate::Transport
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      it "refuses RFC 1918 private space" do
        {"10.0.0.5", "172.16.3.4", "192.168.1.1"}.each do |address|
          with_resolver([address]) do
            interp, _ = make_interp(grants: net_grants)
            eval = interp.eval(<<-RUBY)
            begin
              Legate.fetch("https://api.example.com/")
              "no error"
            rescue Legate::Transport
              "caught"
            end
            RUBY
            eval.as_string.should eq "caught"
          end
        end
      end

      it "refuses carrier-grade NAT space" do
        with_resolver(["100.64.0.1"]) do
          interp, _ = make_interp(grants: net_grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("https://api.example.com/")
            "no error"
          rescue Legate::Transport
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      it "refuses IPv6 loopback and unique-local addresses" do
        {"::1", "fd00::1", "fe80::1"}.each do |address|
          with_resolver([address]) do
            interp, _ = make_interp(grants: net_grants)
            eval = interp.eval(<<-RUBY)
            begin
              Legate.fetch("https://api.example.com/")
              "no error"
            rescue Legate::Transport
              "caught"
            end
            RUBY
            eval.as_string.should eq "caught"
          end
        end
      end

      # The bypass this check would otherwise miss entirely: an
      # IPv4-mapped IPv6 address is not a dotted quad and matches
      # none of the IPv6 prefixes, so it needs unwrapping first.
      it "refuses an IPv4-mapped IPv6 loopback address in either spelling" do
        with_resolver(["::ffff:127.0.0.1"]) do
          interp, _ = make_interp(grants: net_grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("https://api.example.com/")
            "no error"
          rescue Legate::Transport
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      # EVERY address is checked, not just the first — a host whose A
      # record is benign and whose AAAA record points at the metadata
      # service must still be refused.
      it "refuses when only ONE of several addresses is blocked" do
        with_resolver(["93.184.216.34", "169.254.169.254"]) do
          interp, _ = make_interp(grants: net_grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("https://api.example.com/")
            "no error"
          rescue Legate::Transport
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      it "refuses a host that resolves to nothing at all" do
        with_resolver([] of String) do
          interp, _ = make_interp(grants: net_grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("https://api.example.com/")
            "no error"
          rescue Legate::Transport
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end
    end

    # The `local: true` opt-in. §8.2's confused-deputy problem is a
    # script reaching an internal address it never NAMED; a policy
    # that names `localhost` itself is not confused.
    describe "local: true" do
      local_grants = ->(host : String, port : Int32) do
        rule = Legate::NetRule.new(host: host, scheme: "http", ports: [port], local: true)
        Legate::Grants.new(net_rules: [rule], net_methods: ["get"])
      end

      it "still refuses loopback for a rule without the opt-in" do
        with_resolver(["127.0.0.1"]) do
          rule = Legate::NetRule.new(host: "localhost", scheme: "http", ports: [11434])
          grants = Legate::Grants.new(net_rules: [rule], net_methods: ["get"])
          interp, _ = make_interp(grants: grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://localhost:11434/api/tags")
            "no error"
          rescue Legate::Transport
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      # Past the address check and on to the transport, which then
      # fails because nothing is listening — the point being that the
      # SSRF check no longer refuses it. A `Transport` from a refused
      # ADDRESS and one from a refused CONNECTION are distinguished by
      # message.
      #
      # THE PORT IS PROVEN UNBOUND rather than assumed. This spec used
      # 11434, and "nothing is listening" is not true of that port on
      # a machine running Ollama — or forwarding one over `ssh -L`,
      # which binds it on loopback exactly where this connects. The
      # fetch then SUCCEEDS, the script returns "no error", and the
      # old assertion passed vacuously because "no error" happens not
      # to contain "local: true". A test that silently stops testing
      # is worse than one that fails, and this one also quietly sent a
      # request to whatever was on the other end of the tunnel.
      #
      # Binding a port and releasing it hands back one the OS is not
      # currently giving to anyone, so the connection is refused
      # immediately and deterministically. The `should_not eq` is the
      # other half of the fix: an assertion phrased purely as an
      # absence cannot tell success from failure.
      it "lets a rule with the opt-in past the address check" do
        unbound_port = TCPServer.open("127.0.0.1", 0) { |server| server.local_address.port }

        with_resolver(["127.0.0.1"]) do
          interp, _ = make_interp(grants: local_grants.call("localhost", unbound_port))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://localhost:#{unbound_port}/api/tags")
            "no error"
          rescue Legate::Transport => e
            e.message
          end
          RUBY
          eval.as_string.should_not eq "no error"
          eval.as_string.should_not contain "local: true"
        end
      end

      # WHAT THIS ASSERTS is only that the §8.2 address check stopped
      # refusing — everything after that point is incidental, and
      # deliberately not pinned to one failure class.
      #
      # Unlike its sibling above, this resolves to a ROUTABLE RFC 1918
      # address, so the connection attempt genuinely leaves the
      # machine. What happens next depends on the network the machine
      # is attached to: a host that refuses gives `Transport` in
      # milliseconds, one that silently drops gives `Timeout` after
      # the full duration. Both prove the same thing. An earlier
      # version rescued only `Transport` and so failed with a 30s hang
      # on any network where 192.168.1.50 black-holes rather than
      # refuses — a property of the tester's LAN, not of Adjutant.
      # `timeout: 1` bounds the damage either way.
      it "lets a rule with the opt-in reach RFC 1918 space" do
        with_resolver(["192.168.1.50"]) do
          interp, _ = make_interp(grants: local_grants.call("ollama.internal", 11434))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://ollama.internal:11434/api/tags", timeout: 1)
            "no error"
          rescue Legate::Transport => e
            e.message
          rescue Legate::Timeout => e
            e.message
          end
          RUBY
          eval.as_string.should_not eq "no error"
          eval.as_string.should_not contain "local: true"
        end
      end

      # The line that must hold no matter what a policy says. Even
      # with local: true, the metadata endpoint stays refused.
      it "still refuses the cloud metadata address" do
        with_resolver(["169.254.169.254"]) do
          interp, _ = make_interp(grants: local_grants.call("api.example.com", 80))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://api.example.com/")
            "no error"
          rescue Legate::Transport => e
            e.message
          end
          RUBY
          eval.as_string.should contain "link-local"
        end
      end

      it "still refuses IPv6 link-local even with the opt-in" do
        with_resolver(["fe80::1"]) do
          interp, _ = make_interp(grants: local_grants.call("api.example.com", 80))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://api.example.com/")
            "no error"
          rescue Legate::Transport => e
            e.message
          end
          RUBY
          eval.as_string.should contain "link-local"
        end
      end

      it "names the remedy when refusing loopback without the opt-in" do
        with_resolver(["127.0.0.1"]) do
          rule = Legate::NetRule.new(host: "localhost", scheme: "http", ports: [11434])
          grants = Legate::Grants.new(net_rules: [rule], net_methods: ["get"])
          interp, _ = make_interp(grants: grants)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://localhost:11434/api/tags")
            "no error"
          rescue Legate::Transport => e
            e.message
          end
          RUBY
          eval.as_string.should contain "local: true"
        end
      end
    end

    describe "kwarg validation" do
      it "raises TypeError (R036) for a wrong-typed timeout:" do
        interp, _ = make_interp(grants: net_grants)
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch("https://api.example.com/", timeout: "soon")
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end

      it "raises TypeError (R036) for a wrong-typed headers:" do
        interp, _ = make_interp(grants: net_grants)
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch("https://api.example.com/", headers: "Accept: text/plain")
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end

      it "raises TypeError (R036) for a headers: hash with a non-String value" do
        interp, _ = make_interp(grants: net_grants)
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch("https://api.example.com/", headers: { "X-Count" => 3 })
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end

      it "raises TypeError (R036) for a wrong-typed body:" do
        interp, _ = make_interp(grants: net_grants(methods: ["get", "post"]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch("https://api.example.com/", method: :post, body: 42)
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end

      it "validates kwargs before authorizing, consuming no audit record" do
        interp, _ = make_interp(grants: net_grants)
        interp.eval(<<-RUBY)
        begin
          Legate.fetch("https://api.example.com/", timeout: "soon")
        rescue TypeError
        end
        RUBY
        interp.broker.audit_log.records.select { |r| r.verb == "net" }.size.should eq 0
      end

      # Staged, not silent. A script asking for a stream and quietly
      # receiving a buffered String would appear to work right up
      # until a response too large to hold in memory.
      it "raises Legate::Transport for the not-yet-implemented stream: true" do
        interp, _ = make_interp(grants: net_grants)
        eval = interp.eval(<<-RUBY)
        begin
          Legate.fetch("https://api.example.com/", stream: true)
          "no error"
        rescue Legate::Transport
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    # --- Recorded interactions ---------------------------------------
    #
    # These need a real server ONCE, to record. Every run after that
    # replays from `spec/transcripts/`. In CI `record_mode` is `:none`,
    # so a missing transcript fails the build rather than silently
    # reaching the network.
    #
    # `httpbin.org` is the endpoint of convenience here: stable,
    # unauthenticated, and purpose-built for exactly these shapes. If
    # it proves flaky at record time, any equivalent host works —
    # substitute the host in both the policy and the URL.
    describe "recorded round trips" do
      recorded_host = "httpbin.org"

      it "returns a Legate::Response for a plain GET" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_get", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            eval = interp.eval(%(Legate.fetch("https://#{recorded_host}/get").status))
            eval.as_int.should eq 200
          end
        end
      end

      it "exposes downcased response headers" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_get", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            eval = interp.eval(%(Legate.fetch("https://#{recorded_host}/get").headers["content-type"]))
            eval.as_string.should contain "application/json"
          end
        end
      end

      it "parses a JSON body through Response#json" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_get", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            eval = interp.eval(%(Legate.fetch("https://#{recorded_host}/get").json["url"]))
            eval.as_string.should contain recorded_host
          end
        end
      end

      # §4.5's boundary, stated as a test: a 500 is an ANSWER. Nothing
      # in this verb turns a status code into an exception.
      it "returns a 500 as data rather than raising" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_500", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            eval = interp.eval(<<-RUBY)
            response = Legate.fetch("https://#{recorded_host}/status/500")
            [response.status, response.ok?]
            RUBY
            arr = eval.as_array.to_a
            arr[0].as_int.should eq 500
            arr[1].as_bool.should be_false
          end
        end
      end

      it "sends a POST body and gets it back" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_post", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host, ["get", "post"]))
            eval = interp.eval(<<-RUBY)
            response = Legate.fetch("https://#{recorded_host}/post", method: :post, body: "hello legate")
            response.json["data"]
            RUBY
            eval.as_string.should eq "hello legate"
          end
        end
      end

      it "joins an Array body into one request body" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_post_array", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host, ["get", "post"]))
            eval = interp.eval(<<-RUBY)
            response = Legate.fetch("https://#{recorded_host}/post", method: :post, body: ["a", "b", "c"])
            response.json["data"]
            RUBY
            eval.as_string.should eq "abc"
          end
        end
      end

      it "follows a redirect and reports the FINAL url" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_redirect", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            eval = interp.eval(%(Legate.fetch("https://#{recorded_host}/redirect/1").url))
            eval.as_string.should contain "/get"
          end
        end
      end

      it "raises Legate::Transport when the redirect budget is spent" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_redirect_loop", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            eval = interp.eval(<<-RUBY)
            begin
              Legate.fetch("https://#{recorded_host}/redirect/6", redirects: 2)
              "no error"
            rescue Legate::Transport
              "caught"
            end
            RUBY
            eval.as_string.should eq "caught"
          end
        end
      end

      it "raises Legate::TooLarge when the response exceeds limit:" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_too_large", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            eval = interp.eval(<<-RUBY)
            begin
              Legate.fetch("https://#{recorded_host}/bytes/4096", limit: 128)
              "no error"
            rescue Legate::TooLarge
              "caught"
            end
            RUBY
            eval.as_string.should eq "caught"
          end
        end
      end

      it "logs exactly one :allowed audit record for a single-hop fetch" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_get", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            interp.eval(%(Legate.fetch("https://#{recorded_host}/get")))
            records = interp.broker.audit_log.records.select { |r| r.verb == "net" }
            records.size.should eq 1
            records.first.decision.should eq :allowed
            records.first.subject.should eq "https://#{recorded_host}:443"
          end
        end
      end

      # Each hop authorizes independently, so a two-hop fetch leaves
      # two records — the audit log records what was attempted, and a
      # redirect is a second, separate egress.
      it "logs one audit record per redirect hop" do
        resolving_or_placeholder do
          Wiretap.intercept("legate_fetch_redirect", mode: RECORDED_MODE) do
            interp, _ = make_interp(grants: net_grants(recorded_host))
            interp.eval(%(Legate.fetch("https://#{recorded_host}/redirect/1")))
            interp.broker.audit_log.records.select { |r| r.verb == "net" }.size.should eq 2
          end
        end
      end
    end

    # --- The payload redirect rule (§4.5) ----------------------------
    #
    # Hand-written transcripts, and `with_resolver` rather than
    # `resolving_or_placeholder`: these never need a live host, so
    # nothing here should depend on DNS or be re-recordable. See
    # `canary_interception.json` for the same reasoning.
    #
    # Each interaction's `body_digest` is the SHA-256 of its request
    # body, and the harness matches on it as well as method and URL —
    # so a body here must be kept byte-identical to the one the
    # corresponding `Legate.fetch` call sends, or the match fails with
    # "the request body digest differed" rather than anything about
    # redirects.
    describe "redirects on a request that carried a body" do
      payload_host = "api.example.com"

      it "raises Legate::Redirect rather than following a 307" do
        with_resolver(["93.184.216.34"]) do
          Wiretap.intercept("legate_fetch_redirect_payload", mode: :none) do
            interp, _ = make_interp(grants: net_grants(payload_host, ["get", "post"]))
            eval = interp.eval(<<-RUBY)
            begin
              Legate.fetch("https://#{payload_host}/orders", method: :post, body: "an order")
              "followed"
            rescue Legate::Redirect
              "handed back"
            end
            RUBY
            eval.as_string.should eq "handed back"
          end
        end
      end

      # The whole reason the error carries data: a script auto-follows
      # one status and surfaces another, without parsing the message.
      it "carries the status and location for the script to branch on" do
        with_resolver(["93.184.216.34"]) do
          Wiretap.intercept("legate_fetch_redirect_payload", mode: :none) do
            interp, _ = make_interp(grants: net_grants(payload_host, ["get", "post"]))
            eval = interp.eval(<<-RUBY)
            status = nil
            target = nil
            begin
              Legate.fetch("https://#{payload_host}/orders", method: :post, body: "an order")
            rescue Legate::Redirect => e
              status = e.status
              target = e.location
            end
            [status, target]
            RUBY
            result = eval.as_array.to_a
            result[0].as_int.should eq 307
            result[1].as_string.should eq "https://#{payload_host}/v2/orders"
          end
        end
      end

      # 303 is handed back too. The rule is uniform across all five
      # codes deliberately — see §4.5 — and `status` is what lets a
      # script that wants to auto-follow this one do so in a line.
      it "hands back a 303 as well, with its own status" do
        with_resolver(["93.184.216.34"]) do
          Wiretap.intercept("legate_fetch_redirect_payload", mode: :none) do
            interp, _ = make_interp(grants: net_grants(payload_host, ["get", "post"]))
            eval = interp.eval(<<-RUBY)
            code = nil
            begin
              Legate.fetch("https://#{payload_host}/submit", method: :post, body: "a form")
            rescue Legate::Redirect => e
              code = e.status
            end
            code
            RUBY
            eval.as_int.should eq 303
          end
        end
      end

      # The failure this rule exists to prevent: a 301 on a POST would
      # conventionally degrade to GET, drop the body, and return a 2xx
      # for a request that never happened.
      it "hands back a 301 rather than silently degrading it to a GET" do
        with_resolver(["93.184.216.34"]) do
          Wiretap.intercept("legate_fetch_redirect_payload", mode: :none) do
            interp, _ = make_interp(grants: net_grants(payload_host, ["get", "post"]))
            eval = interp.eval(<<-RUBY)
            code = nil
            begin
              Legate.fetch("https://#{payload_host}/legacy", method: :post, body: "data")
            rescue Legate::Redirect => e
              code = e.status
            end
            code
            RUBY
            eval.as_int.should eq 301
          end
        end
      end

      # The predicate keys on the BODY, not the method — a POST with
      # nothing to send has nothing at stake and follows as normal.
      it "follows a redirect on a body-less POST" do
        with_resolver(["93.184.216.34"]) do
          Wiretap.intercept("legate_fetch_redirect_no_payload", mode: :none) do
            interp, _ = make_interp(grants: net_grants(payload_host, ["get", "post"]))
            eval = interp.eval(%(Legate.fetch("https://#{payload_host}/ping", method: :post).body))
            eval.as_string.should eq "pong"
          end
        end
      end

      # An empty String is no payload. Raising here would be pedantry:
      # there is nothing to replay and nothing to silently drop.
      it "treats an empty body as no body and follows the redirect" do
        with_resolver(["93.184.216.34"]) do
          Wiretap.intercept("legate_fetch_redirect_no_payload", mode: :none) do
            interp, _ = make_interp(grants: net_grants(payload_host, ["get", "post"]))
            eval = interp.eval(%(Legate.fetch("https://#{payload_host}/empty", method: :post, body: "").body))
            eval.as_string.should eq "ok"
          end
        end
      end

      # Handed back before the second hop is attempted, so the audit
      # log shows exactly one egress — the script has not yet decided
      # whether the body should go to the new host.
      it "logs one audit record, not two, when it hands a redirect back" do
        with_resolver(["93.184.216.34"]) do
          Wiretap.intercept("legate_fetch_redirect_payload", mode: :none) do
            interp, _ = make_interp(grants: net_grants(payload_host, ["get", "post"]))
            interp.eval(<<-RUBY)
            begin
              Legate.fetch("https://#{payload_host}/orders", method: :post, body: "an order")
            rescue Legate::Redirect => e
              nil
            end
            RUBY
            interp.broker.audit_log.records.select { |r| r.verb == "net" }.size.should eq 1
          end
        end
      end
    end
  end
end
