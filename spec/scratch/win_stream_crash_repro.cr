# Windows crash repro, v3. Versions 1 and 2 both exited 0 everywhere.
#
# ## Why the first two were wrong, since that is the useful part
#
# v1 read the body synchronously — no producer fiber at all. v2 added
# a producer fiber and a channel, but as a HAND-COPY of
# `Utils::HttpResponseStream` rather than the class itself. I rebuilt
# the SHAPE and assumed the shape was the thing. This version uses the
# real class, and nothing else from Adjutant.
#
# ## What the suite has already ruled out, for free
#
# Nothing here needs to test these; they are green on Windows today:
#
#   - Script exceptions unwinding through VM frames.
#     `begin_rescue_ensure/vm_spec.cr` has ten cases escaping `eval`
#     uncaught, one of them several call frames deep.
#   - The Crystal -> VM -> Crystal -> VM -> raise sandwich, with a
#     stream in the middle, teardown in an `ensure`, and an
#     `open_sources` assertion afterwards.
#     `open_sources_spec.cr:305` ("closes a stream whose walk raised")
#     is STRUCTURALLY IDENTICAL to the crashing test and passes.
#
# The only difference between that passing test and the crashing one
# is what feeds the stream. `Legate.bytes` reads a file inline on the
# consumer's own fiber. `HttpResponseStream` has a PRODUCER FIBER that
# is still live — and parked inside a socket read — when cancellation
# arrives.
#
# ## The hypothesis
#
# Cancelling an `HttpResponseStream` whose producer fiber is parked in
# a socket read terminates the process on Windows. `close` closes the
# channel and does a single `Fiber.yield`, on the stated assumption
# that "the producer's next scheduled step is the raise" — which holds
# for a fiber parked on `send`, not one parked on I/O.
#
# ## The three cases, and why each is here
#
#   A  Exhaust the body fully, then close. Producer already finished.
#      The control: if this dies, cancellation is not the issue.
#   B  Take one chunk, then close. Producer most likely parked on
#      SEND. Mirrors the PASSING "stream is abandoned" test.
#   C  Take one chunk, then close from an `ensure` while an exception
#      unwinds. Mirrors the CRASHING "raises mid-walk" test.
#
# B and C differ ONLY by the unwinding. If C dies and B lives, the
# unwind is required and that is the upstream report. If both die, the
# raise is irrelevant and it is purely fiber-parked-on-read
# cancellation — which would ALSO mean the passing "abandoned" test is
# passing by luck, and is the more alarming outcome.
#
# Each case repeats, because a scheduler race will not show every run.
#
# Expected on Linux/macOS: all three print DONE, exit 0.
# Run:  crystal run --debug spec/scratch/win_stream_crash_repro.cr
# Then: echo $LASTEXITCODE   (PowerShell)

require "http/server"
require "http/client"
require "../../src/adjutant/utils/http_response_stream"

BODY_SIZE  = 40_000
CHUNK_SIZE =  8_192
REPEATS    =     25

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
    server.close rescue nil
  end
end

# The real class, opened exactly as `fetch.cr`'s `perform_streaming`
# does — minus the pinning, which is a plain socket detail and cannot
# matter here (the address IS 127.0.0.1 either way).
def open_stream(port : Int32) : Adjutant::Utils::HttpResponseStream
  client = HTTP::Client.new("127.0.0.1", port)
  client.read_timeout = 5.seconds
  request = HTTP::Request.new("GET", "/", HTTP::Headers.new)
  Adjutant::Utils::HttpResponseStream.open(client, request, CHUNK_SIZE)
end

# --- A: producer already finished -------------------------------
puts "A: exhaust fully, then close"
with_server do |port|
  REPEATS.times do
    stream = open_stream(port)
    while stream.next_chunk
    end
    stream.close
  end
end
puts "A: DONE"

# --- B: producer parked on SEND ---------------------------------
# The passing "stream is abandoned" test.
puts "B: one chunk, then close"
with_server do |port|
  REPEATS.times do
    stream = open_stream(port)
    stream.next_chunk
    stream.close
  end
end
puts "B: DONE"

# --- C: producer parked, close during unwind --------------------
# The crashing "raises mid-walk" test. The `ensure` mirrors
# `interpreter.cr`'s `ensure ... open_sources.close_all`.
puts "C: one chunk, raise, close from ensure"
with_server do |port|
  REPEATS.times do |i|
    stream = open_stream(port)
    begin
      stream.next_chunk
      raise "boom"
    rescue
      # Swallowed as expect_raises would.
    ensure
      stream.close
    end
    puts "C: iteration #{i} survived" if i % 5 == 0
  end
end
puts "C: DONE"

puts "ALL DONE"
