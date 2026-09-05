# Standalone repro for the Windows-only hard crash seen in
# `fetch_stream_spec.cr` — "closes the connection when the script
# raises mid-walk". No Adjutant, no spec framework, no fibers beyond
# the one the server needs.
#
# The hypothesis this is testing, stated so a null result is still
# informative:
#
#   Closing an HTTP::Client::Response whose body has been partially
#   read — i.e. with a read still outstanding on the socket — CRASHES
#   the process on Windows when the close happens while a Crystal
#   exception is unwinding the stack.
#
# Case A closes after a NORMAL return. Case B closes from an `ensure`
# during unwinding. Adjutant does exactly B, in
# `interpreter.cr`'s `ensure ... open_sources.close_all`, and exactly
# A in the abandoned-stream path — which is precisely the pair that
# bisection separated: A passes, B kills the run.
#
# Expected on Linux/macOS: both print DONE.
# If the hypothesis holds on Windows: A prints, B crashes with
# 0xC0000005 and no output after "B: closing".
#
# Run:  crystal run --debug win_stream_repro.cr
# Then: echo $LASTEXITCODE   (PowerShell)

require "http/server"
require "http/client"

BODY_SIZE = 40_000

def with_server(&)
  server = HTTP::Server.new do |context|
    context.response.print("y" * BODY_SIZE)
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield address.port
  ensure
    server.close
  end
end

# Read ONE small chunk and stop, leaving the rest of the body
# unread and the socket mid-transfer. This is what
# `.body.first(1)` does in the spec.
def partial_read(port : Int32, &)
  client = HTTP::Client.new("127.0.0.1", port)
  client.get("/") do |response|
    buffer = Bytes.new(64)
    response.body_io.read(buffer)
    yield client
  end
end

# --- Case A: close after a normal return -------------------------
# Matches the passing "stream is abandoned" test.
with_server do |port|
  puts "A: partial read, normal return"
  partial_read(port) { |client| client.close }
  puts "A: DONE"
end

# --- Case B: close from an ensure, mid-unwind --------------------
# Matches the crashing "raises mid-walk" test, and Adjutant's own
# `ensure ... close_all` teardown.
with_server do |port|
  puts "B: partial read, raising mid-walk"
  begin
    partial_read(port) do |client|
      begin
        raise "boom"
      ensure
        puts "B: closing"
        client.close
      end
    end
  rescue ex
    puts "B: rescued #{ex.message}"
  end
  puts "B: DONE"
end

puts "ALL DONE"
