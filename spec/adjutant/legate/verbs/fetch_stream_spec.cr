require "../../../spec_helper"
require "http/server"

private alias Handler = HTTP::Server::Context ->

# A real loopback server, as in `http_response_stream_spec.cr` and for
# the same reason: what is under test here is what happens to a LIVE
# connection — that it survives between pulls, that abandoning a
# stream closes it, that `stream_limit` drops it mid-body. Wiretap
# replays a body from an `IO::Memory`, which cannot exhibit any of
# that, so a transcript would be testing the harness rather than the
# verb. The buffered path's own specs stay on transcripts, where the
# interesting part is policy rather than sockets.
# Every socket-facing part of this helper swallows `IO::Error`, and
# that is load-bearing rather than defensive habit — it is what these
# specs are FOR.
#
# Several tests here abandon a response mid-write on purpose: the
# server prints 40_000 bytes, the script pulls one chunk and drops the
# connection. That is the behaviour under test. From the SERVER's side
# it is a peer that vanished mid-write, which raises. Unix gives
# `EPIPE`/`ECONNRESET`, which `HTTP::Server` already swallows; Windows
# gives `WSAECONNABORTED`/`WSAECONNRESET`, which escaped and — because
# an unhandled exception in a SPAWNED FIBER terminates the whole
# process in Crystal — killed the run with no failure message and no
# test name attached to it. Diagnosed 2026-09-04 from a Windows CI run
# that reported only "Process terminated abnormally"; it is a race, so
# WHICH abandoning test dies varies.
#
# Three separate places can raise, and all three need covering — a
# rescue on only `listen` still lets the handler's own `print` to a
# dead socket through:
#
#   1. `handler.call` — writing the response body to a closed peer.
#   2. `server.listen` — accepting or reading from one.
#   3. `server.close` — tearing down with a connection still in a bad
#      state.
#
# Only `IO::Error` (which `Socket::Error` is under) is swallowed, and
# only here in the scaffolding. A bare `rescue` would hide a genuine
# assertion failure raised from inside a handler, which would turn a
# real bug into a silent pass — the opposite of the problem this is
# fixing.
private def with_stream_server(handler : Handler, &)
  server = HTTP::Server.new do |context|
    begin
      handler.call(context)
    rescue IO::Error
      # The client went away mid-response. Expected here.
    end
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn do
    begin
      server.listen
    rescue IO::Error
      # As above, from the accept/read side.
    end
  end
  Fiber.yield
  begin
    yield address.port
  ensure
    begin
      server.close
    rescue IO::Error
      # Closing while a connection is already broken.
    end
  end
end

# `local: true` because the server is on 127.0.0.1, which §8.2 refuses
# unless the matching rule opts in — the same opt-in a policy naming
# `localhost:11434` would need.
private def loopback_grants(port : Int32, limits : Adjutant::Legate::Limits? = nil) : Adjutant::Legate::Grants
  Adjutant::Legate::Grants.new(
    net_rules: [Adjutant::Legate::NetRule.new(
      host: "127.0.0.1", scheme: "http", ports: [port], local: true,
    )],
    net_methods: ["get", "post"],
    limits: limits || Adjutant::Legate::Limits.new,
  )
end

module Adjutant
  describe "Legate.fetch stream: true" do
    it "returns a Legate::Bytes rather than a String" do
      with_stream_server(->(context : HTTP::Server::Context) {
        context.response.print("hello streaming")
      }) do |port|
        interp, _ = make_interp(grants: loopback_grants(port))
        eval = interp.eval(<<-RUBY)
        response = Legate.fetch("http://127.0.0.1:#{port}/", stream: true)
        response.body.is_a?(Legate::Bytes)
        RUBY
        eval.truthy?.should be_true
      end
    end

    it "yields the whole body across chunks" do
      payload = "abcdefghij" * 300 # 3_000 bytes
      with_stream_server(->(context : HTTP::Server::Context) {
        context.response.print(payload)
      }) do |port|
        interp, _ = make_interp(grants: loopback_grants(port))
        eval = interp.eval(<<-RUBY)
        response = Legate.fetch("http://127.0.0.1:#{port}/", stream: true)
        total = 0
        response.body.each { |chunk| total = total + chunk.size }
        total
        RUBY
        eval.as_int.should eq payload.bytesize
      end
    end

    it "exposes status and headers alongside the streamed body" do
      with_stream_server(->(context : HTTP::Server::Context) {
        context.response.status_code = 201
        context.response.headers["X-Marker"] = "here"
        context.response.print("x")
      }) do |port|
        interp, _ = make_interp(grants: loopback_grants(port))
        eval = interp.eval(<<-RUBY)
        response = Legate.fetch("http://127.0.0.1:#{port}/", stream: true)
        [response.status, response.headers["x-marker"]]
        RUBY
        result = eval.as_array.to_a
        result[0].as_int.should eq 201
        result[1].as_string.should eq "here"
      end
    end

    it "records streamed bytes against the run's read budget" do
      payload = "z" * 2_048
      with_stream_server(->(context : HTTP::Server::Context) {
        context.response.print(payload)
      }) do |port|
        interp, _ = make_interp(grants: loopback_grants(port))
        interp.eval(<<-RUBY)
        Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.each { |c| c }
        RUBY
        interp.broker.budget.total_read.should eq payload.bytesize
      end
    end

    describe "connection lifetime" do
      it "deregisters the source once the body is fully walked" do
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.print("complete")
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port))
          interp.eval(<<-RUBY)
          Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.each { |c| c }
          RUBY
          interp.broker.open_sources.size.should eq 0
        end
      end

      # The case the whole registry exists for, now with a socket
      # rather than a file handle behind it: `first(1)` halts the walk
      # without exhausting the source, so the iterator's own
      # close-on-exhaustion is never reached and run teardown is what
      # releases the connection.
      it "closes the connection when the stream is abandoned" do
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.print("y" * 40_000)
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port))
          interp.eval(<<-RUBY)
          Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.first(1)
          RUBY
          interp.broker.open_sources.size.should eq 0
        end
      end

      it "closes the connection when the script raises mid-walk" do
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.print("w" * 40_000)
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port))
          expect_raises(Exception) do
            interp.eval(<<-RUBY)
            Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.each { |c| raise "boom" }
            RUBY
          end
          interp.broker.open_sources.size.should eq 0
        end
      end

      it "counts against max_open_streams" do
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.print("v" * 10_000)
        }) do |port|
          limits = Legate::Limits.new(max_open_streams: 1)
          interp, _ = make_interp(grants: loopback_grants(port, limits))
          eval = interp.eval(<<-RUBY)
          Legate.fetch("http://127.0.0.1:#{port}/", stream: true)
          caught = false
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", stream: true)
          rescue Legate::TooMany => e
            caught = true
          end
          caught
          RUBY
          eval.truthy?.should be_true
        end
      end
    end

    describe "stream_limit" do
      # Enforced as bytes arrive, so a runaway response is refused
      # partway rather than after it has all been pulled.
      #
      # Reads are `READ_CHUNK_SIZE` (64 KiB) granular, so the limit
      # sits between one chunk and two and the body spans three —
      # otherwise the first read breaches the limit and "partway" is
      # not what is being tested at all.
      it "raises Legate::TooLarge partway through an over-limit body" do
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.print("q" * 200_000)
        }) do |port|
          limits = Legate::Limits.new(stream_limit: 100_000_i64)
          interp, _ = make_interp(grants: loopback_grants(port, limits))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.each { |c| c }
            "no error"
          rescue Legate::TooLarge
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end

      # The connection must be dropped before the raise — a script
      # that rescues `TooLarge` must not be left holding a socket to a
      # server still sending.
      it "closes the connection when it refuses an over-limit body" do
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.print("q" * 50_000)
        }) do |port|
          limits = Legate::Limits.new(stream_limit: 4_096_i64)
          interp, _ = make_interp(grants: loopback_grants(port, limits))
          interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.each { |c| c }
          rescue Legate::TooLarge
          end
          RUBY
          interp.broker.open_sources.size.should eq 0
        end
      end

      # A streamed body is clamped against `stream_limit`, NOT
      # `fetch_limit` — clamping it against the memory cap would make
      # `stream: true` useless for the bodies it exists for. A small
      # `fetch_limit` with a large `stream_limit` proves which one is
      # consulted.
      it "is not bounded by fetch_limit" do
        payload = "p" * 20_000
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.print(payload)
        }) do |port|
          limits = Legate::Limits.new(fetch_limit: 1_024_i64, stream_limit: 1_048_576_i64)
          interp, _ = make_interp(grants: loopback_grants(port, limits))
          eval = interp.eval(<<-RUBY)
          total = 0
          Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.each { |c| total = total + c.size }
          total
          RUBY
          eval.as_int.should eq payload.bytesize
        end
      end
    end

    describe "redirects" do
      # Every hop runs through the streaming path, and an intermediate
      # hop is opened only far enough to read its status and Location
      # before being closed unread.
      it "follows a redirect and streams the final body" do
        with_stream_server(->(context : HTTP::Server::Context) {
          if context.request.path == "/moved"
            context.response.status_code = 302
            context.response.headers["Location"] = "/final"
            context.response.print("redirect notice")
          else
            context.response.print("final body")
          end
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port))
          eval = interp.eval(<<-RUBY)
          response = Legate.fetch("http://127.0.0.1:#{port}/moved", stream: true)
          parts = []
          response.body.each { |c| parts << c.to_s }
          [response.url, parts.join]
          RUBY
          result = eval.as_array.to_a
          result[0].as_string.should contain "/final"
          result[1].as_string.should eq "final body"
        end
      end

      it "leaves no source registered for the abandoned intermediate hop" do
        with_stream_server(->(context : HTTP::Server::Context) {
          if context.request.path == "/moved"
            context.response.status_code = 302
            context.response.headers["Location"] = "/final"
            context.response.print("redirect notice")
          else
            context.response.print("final body")
          end
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port))
          interp.eval(<<-RUBY)
          Legate.fetch("http://127.0.0.1:#{port}/moved", stream: true).body.each { |c| c }
          RUBY
          interp.broker.open_sources.size.should eq 0
        end
      end

      # The payload rule applies to the streaming path identically —
      # it is about the request's body, not the response's shape.
      it "hands back a redirect on a streamed request that carried a body" do
        with_stream_server(->(context : HTTP::Server::Context) {
          context.response.status_code = 307
          context.response.headers["Location"] = "/elsewhere"
          context.response.print("moved")
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port))
          eval = interp.eval(<<-RUBY)
          code = nil
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", method: :post, body: "payload", stream: true)
          rescue Legate::Redirect => e
            code = e.status
          end
          code
          RUBY
          eval.as_int.should eq 307
        end
      end
    end
  end
end
