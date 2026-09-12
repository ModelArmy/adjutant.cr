require "../../spec_helper"
require "http/server"

private alias Handler = HTTP::Server::Context ->

# A real HTTP server on a loopback port, for the length of one block.
#
# Deliberately NOT the Wiretap harness: this class is the layer
# underneath Legate, and the behaviour under test is what happens to a
# live connection — that it stays open across pulls, that it closes on
# abandonment, that a server dying mid-body surfaces as an error
# rather than as a clean end. A replayed `IO::Memory` cannot exhibit
# any of that, so a transcript here would test the harness rather than
# the code.
private def with_server(handler : Handler, &)
  server = HTTP::Server.new { |context| handler.call(context) }
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield address.port
  ensure
    server.close
  end
end

private def client_for(port : Int32, read_timeout : Time::Span? = nil) : HTTP::Client
  client = HTTP::Client.new("127.0.0.1", port)
  client.read_timeout = read_timeout if read_timeout
  client
end

private def get_request : HTTP::Request
  HTTP::Request.new("GET", "/")
end

module Adjutant
  describe Utils::HttpResponseStream do
    it "exposes the status and headers before any chunk is pulled" do
      with_server(->(context : HTTP::Server::Context) {
        context.response.status_code = 201
        context.response.headers["X-Marker"] = "here"
        context.response.print("body")
      }) do |port|
        stream = Utils::HttpResponseStream.open(client_for(port), get_request)
        begin
          stream.status.should eq 201
          stream.headers["X-Marker"].should eq "here"
        ensure
          stream.close
        end
      end
    end

    it "yields the whole body across successive chunks" do
      payload = "abcdefghij" * 500 # 5_000 bytes
      with_server(->(context : HTTP::Server::Context) {
        context.response.print(payload)
      }) do |port|
        stream = Utils::HttpResponseStream.open(client_for(port), get_request, chunk_size: 256)
        begin
          received = IO::Memory.new
          while chunk = stream.next_chunk
            received.write(chunk)
          end
          received.to_s.should eq payload
        ensure
          stream.close
        end
      end
    end

    it "returns nil at the end and keeps returning nil" do
      with_server(->(context : HTTP::Server::Context) { context.response.print("short") }) do |port|
        stream = Utils::HttpResponseStream.open(client_for(port), get_request)
        begin
          stream.next_chunk.should_not be_nil
          stream.next_chunk.should be_nil
          stream.next_chunk.should be_nil
        ensure
          stream.close
        end
      end
    end

    # The point of the class: the connection is still live between
    # pulls, rather than the body having been read into memory up
    # front. Chunk size well below the payload means a second pull can
    # only succeed if the first did not drain everything.
    it "keeps the connection open between pulls" do
      payload = "x" * 20_000
      with_server(->(context : HTTP::Server::Context) {
        context.response.print(payload)
      }) do |port|
        stream = Utils::HttpResponseStream.open(client_for(port), get_request, chunk_size: 1_024)
        begin
          first = stream.next_chunk
          first.should_not be_nil
          first.not_nil!.size.should be <= 1_024

          # Yielding between pulls proves nothing is holding the whole
          # body: the producer is parked mid-response, waiting.
          Fiber.yield
          stream.next_chunk.should_not be_nil
        ensure
          stream.close
        end
      end
    end

    it "handles an empty body without parking forever" do
      with_server(->(context : HTTP::Server::Context) {
        context.response.status_code = 204
      }) do |port|
        stream = Utils::HttpResponseStream.open(client_for(port), get_request)
        begin
          stream.next_chunk.should be_nil
        ensure
          stream.close
        end
      end
    end

    # Each chunk must be its own allocation — the producer and
    # consumer are different fibers, so a reused buffer could be
    # overwritten while the consumer still holds it. Holding two
    # chunks at once and comparing is what would catch that.
    it "gives each chunk its own buffer" do
      with_server(->(context : HTTP::Server::Context) {
        context.response.print("AAAABBBB")
      }) do |port|
        stream = Utils::HttpResponseStream.open(client_for(port), get_request, chunk_size: 4)
        begin
          first = stream.next_chunk.not_nil!
          held = first.dup
          second = stream.next_chunk.not_nil!

          # If the buffer were reused, reading `second` would have
          # overwritten what `first` points at.
          String.new(first).should eq String.new(held)
          String.new(first).should_not eq String.new(second)
        ensure
          stream.close
        end
      end
    end

    describe "abandonment" do
      it "closes without having read the body" do
        with_server(->(context : HTTP::Server::Context) {
          context.response.print("y" * 50_000)
        }) do |port|
          stream = Utils::HttpResponseStream.open(client_for(port), get_request, chunk_size: 512)
          stream.next_chunk.should_not be_nil
          stream.close
          stream.closed?.should be_true
        end
      end

      it "is idempotent" do
        with_server(->(context : HTTP::Server::Context) { context.response.print("z") }) do |port|
          stream = Utils::HttpResponseStream.open(client_for(port), get_request)
          stream.close
          stream.close
          stream.closed?.should be_true
        end
      end

      it "returns nil from next_chunk after close rather than raising" do
        with_server(->(context : HTTP::Server::Context) {
          context.response.print("w" * 10_000)
        }) do |port|
          stream = Utils::HttpResponseStream.open(client_for(port), get_request, chunk_size: 128)
          stream.next_chunk.should_not be_nil
          stream.close
          stream.next_chunk.should be_nil
        end
      end

      # Closing a never-pulled stream leaves the producer parked on
      # its very first body `send`. If cancellation did not reach it,
      # this would hang rather than fail.
      it "closes a stream that was never pulled" do
        with_server(->(context : HTTP::Server::Context) {
          context.response.print("v" * 10_000)
        }) do |port|
          stream = Utils::HttpResponseStream.open(client_for(port), get_request, chunk_size: 128)
          stream.close
          stream.closed?.should be_true
        end
      end
    end

    describe "failures" do
      # The case that must not look like success: a body cut short.
      # Without failures crossing the channel the consumer would see a
      # clean nil and treat a truncated download as complete.
      #
      # A READ TIMEOUT IS REQUIRED HERE, and its absence is what made
      # an earlier version of this spec hang rather than fail. The
      # server promises 10,000 bytes and sends 100; Crystal wraps
      # `body_io` in a fixed-length reader that goes on waiting for
      # the other 9,900, and `HTTP::Server` does not necessarily drop
      # the socket when the handler returns. With no timeout the
      # producer parks in `read` forever and the consumer parks on
      # `receive` behind it.
      #
      # That is not a defect in `HttpResponseStream`: it holds NO
      # timeouts of its own and inherits whatever the client carries,
      # deliberately, so there is one place timeouts are configured
      # rather than two that can disagree. Every real caller sets them
      # — `fetch.cr` sets both from `opts.timeout` — and this spec was
      # the only one that did not.
      it "raises on the consumer's fiber when the body ends early" do
        with_server(->(context : HTTP::Server::Context) {
          context.response.headers["Content-Length"] = "10000"
          context.response.print("a" * 100)
          context.response.flush
          context.response.close
        }) do |port|
          client = client_for(port, read_timeout: 2.seconds)
          stream = Utils::HttpResponseStream.open(client, get_request, chunk_size: 64)
          begin
            expect_raises(Exception) do
              while stream.next_chunk
              end
            end
          ensure
            stream.close
          end
        end
      end

      it "raises on the consumer's fiber when the connection is refused" do
        # Nothing is listening: the port was bound and released.
        server = HTTP::Server.new { }
        address = server.bind_unused_port("127.0.0.1")
        port = address.port
        server.close

        expect_raises(Exception) do
          Utils::HttpResponseStream.open(client_for(port), get_request)
        end
      end
    end
  end
end
