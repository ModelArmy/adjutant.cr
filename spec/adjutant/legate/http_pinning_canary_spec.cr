require "../../spec_helper"

# CANARIES for `src/adjutant/legate/http_client_pinning.cr`.
#
# That file reopens `HTTP::Client` and overrides its private `io`
# method, which means it depends on behaviour of two things it does
# not own: Crystal's standard library, and the record/replay harness
# that patches the same class. Neither dependency is expressed in a
# type signature, so neither breaks loudly. A compiler upgrade that
# reshapes `HTTP::Client#io`, or a harness release that changes where
# it intercepts, would leave the override compiling perfectly and
# behaving wrongly — and "wrongly" here means either silently
# abandoning the §8.2 pinning guarantee or silently letting specs
# reach the real network.
#
# So each spec below asserts ONE assumption directly, using
# `HTTP::Client` on its own rather than going through `Legate.fetch`.
# The point is that when one of these fails, the failure names the
# assumption that changed rather than surfacing as a puzzling
# `Legate.fetch` failure three layers up. **A failure here is
# informational, not necessarily a bug**: it means an assumption needs
# re-examining, and `http_client_pinning.cr`'s own comment updating.
#
# Note what ISN'T here. The override reads `@reconnect`, `@dns_timeout`,
# `@connect_timeout`, `@read_timeout`, `@write_timeout`, `@tls`, `@io`,
# `@host` and `@port` directly. If Crystal renames or removes any of
# them the build FAILS, which is a better canary than any spec — so
# they need no coverage here.
#
# Everything below runs fully offline. `192.0.2.1` is TEST-NET-1
# (RFC 5737), reserved for documentation and guaranteed never to be
# routable; `canary.invalid` is under the reserved `.invalid` TLD
# (RFC 2606) and guaranteed never to resolve. Both are chosen so that
# any accidental real network activity fails immediately and loudly
# rather than reaching something.
private UNROUTABLE   = "192.0.2.1"
private UNRESOLVABLE = "canary.invalid"

# A one-shot HTTP server on an ephemeral loopback port. Yields the
# port and, after the block, the request head the client actually
# sent — which is how the `Host`-header canary below checks what went
# over the wire rather than what the client reports about itself.
private def local_http_server(& : Int32, Array(String) ->)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  request_head = [] of String
  done = Channel(Nil).new

  spawn do
    if socket = server.accept?
      # Read the request head so the client isn't left blocked on a
      # server that never answers. Anything up to the blank line.
      while (line = socket.gets)
        break if line.empty?
        request_head << line
      end
      socket.print("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Type: text/plain\r\n\r\npong")
      socket.flush
      socket.close
    end
    done.send(nil)
  end

  begin
    yield port, request_head
  ensure
    server.close
    done.receive
  end
end

module Adjutant
  describe "HTTP::Client pinning canaries" do
    # ASSUMPTION 1: constructing a client opens no socket; the
    # connection is made lazily on the first request.
    #
    # This is what lets the override sit in `io` at all, and — more
    # importantly — it is what keeps replayed specs offline. If
    # construction ever became eager, every recorded spec in this
    # suite would start dialling out, and pinning would have to be
    # rebuilt around a completely different seam.
    it "opens no socket when a client is constructed" do
      client = HTTP::Client.new(UNROUTABLE, 80)
      client.adjutant_pinned_address.should be_nil
      client.close
    end

    # ASSUMPTION 2: the override is INERT unless opted into. Every
    # other `HTTP::Client` user in the process — including the
    # record/replay harness itself — must be unaffected by the patch.
    #
    # Asserted by behaviour rather than by inspection: an unpinned
    # client pointed at an unresolvable hostname must still fail on
    # DNS, proving it took `previous_def`'s ordinary path.
    it "leaves an unpinned client resolving its hostname normally" do
      client = HTTP::Client.new(UNRESOLVABLE, 80)
      client.connect_timeout = 2.seconds
      client.dns_timeout = 2.seconds
      expect_raises(Exception) do
        client.exec(HTTP::Request.new("GET", "/ping"))
      end
      client.close
    end

    # ASSUMPTION 3 — the core of the whole mechanism: a pinned client
    # connects to the PINNED ADDRESS and never resolves `@host`.
    #
    # Proven by making resolution impossible. The host is
    # `canary.invalid`, which cannot resolve by construction; the pin
    # points at a real local server. A response can therefore only
    # arrive if the address was used and the name never consulted. If
    # this fails, §8.2's pinning guarantee is gone: `Legate.fetch`
    # would be resolving a second time after its address check, which
    # is precisely the DNS-rebinding window the check exists to close.
    it "connects to the pinned address without resolving the hostname" do
      local_http_server do |port, _head|
        client = HTTP::Client.new(UNRESOLVABLE, port)
        client.adjutant_pinned_address = "127.0.0.1"
        client.connect_timeout = 5.seconds
        response = client.get("/ping")
        response.status_code.should eq 200
        response.body.should eq "pong"
        client.close
      end
    end

    # ASSUMPTION 4: pinning does not disturb the client's identity.
    # `#host`, `#port` and `#tls?` must keep reporting the LOGICAL
    # destination, not the pinned address.
    #
    # This is what keeps transcripts keyed on `https://example.com/path`
    # rather than on whichever IP the resolver happened to return on
    # recording day. If it breaks, every committed transcript silently
    # stops matching and the suite starts trying to re-record.
    it "reports the logical host and port, not the pinned address" do
      client = HTTP::Client.new("example.com", 443, tls: true)
      client.adjutant_pinned_address = UNROUTABLE
      client.host.should eq "example.com"
      client.port.should eq 443
      client.tls?.should_not be_nil
      client.close
    end

    it "sends the logical hostname in the Host header, not the pinned address" do
      local_http_server do |port, head|
        client = HTTP::Client.new(UNRESOLVABLE, port)
        client.adjutant_pinned_address = "127.0.0.1"
        client.get("/ping")
        client.close

        host_lines = head.select(&.downcase.starts_with?("host:"))
        host_lines.size.should eq 1
        host_lines.first.should contain UNRESOLVABLE
        host_lines.first.should_not contain "127.0.0.1"
      end
    end

    # ASSUMPTION 5: the record/replay harness intercepts a PLAIN
    # `HTTP::Client` ahead of any connection, even a pinned one.
    #
    # This is what `http_client_pinning.cr` relies on when it insists
    # the receiver's type stay exactly `HTTP::Client` rather than a
    # subclass. If it stops holding, replayed specs across the suite
    # begin using the real network without saying so.
    #
    # Uses `exec(request) { }`, the BLOCK form, because that is the
    # exact call `Legate.fetch` makes. The convenience methods (`#get`
    # and friends) route through a different overload, and a canary
    # that exercises a call the production code never makes is testing
    # somebody else's assumption.
    #
    # `mode: :none` forbids recording, so a missing transcript fails
    # as a clear harness error naming it. Under `:once` the harness
    # would record instead — dialling TEST-NET-1 — making a setup
    # mistake indistinguishable from the regression this canary
    # exists to catch. `connect_timeout` is a backstop: TEST-NET-1
    # blackholes packets rather than refusing them, so anything that
    # does reach the network would otherwise hang rather than fail.
    it "is intercepted by the replay harness before any connection is attempted" do
      Wiretap.intercept("canary_interception", mode: :none) do
        client = HTTP::Client.new(UNRESOLVABLE, 80)
        client.adjutant_pinned_address = UNROUTABLE
        client.connect_timeout = 2.seconds

        request = HTTP::Request.new("GET", "/ping")
        status = 0
        body = ""
        client.exec(request) do |response|
          status = response.status_code
          body = response.body_io? ? response.body_io.gets_to_end : (response.body || "")
        end
        client.close

        # `pong` can only come from the transcript — nothing on
        # TEST-NET-1 is answering.
        status.should eq 200
        body.should eq "pong"
      end
    end

    # ASSUMPTION 6: the harness derives a transcript's identity from
    # `#host`/`#port`/`#tls?`, so a pinned client matches the SAME
    # transcript entry an unpinned one would.
    #
    # Asserted by matching the identical hand-written interaction with
    # the pin removed. If the harness ever started keying on the
    # socket's real peer instead, this would miss and raise.
    it "matches the same transcript entry with or without a pin" do
      Wiretap.intercept("canary_interception", mode: :none) do
        client = HTTP::Client.new(UNRESOLVABLE, 80)
        client.connect_timeout = 2.seconds

        request = HTTP::Request.new("GET", "/ping")
        body = ""
        client.exec(request) do |response|
          body = response.body_io? ? response.body_io.gets_to_end : (response.body || "")
        end
        client.close

        body.should eq "pong"
      end
    end
  end
end
