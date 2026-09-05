# Windows crash repro, v2. v1 returned a clean 0 on all platforms and
# was therefore WRONG — it read the response body synchronously, which
# is the one thing Adjutant never does.
#
# `Utils::HttpResponseStream` (src/adjutant/utils/http_response_stream.cr)
# runs the HTTP read loop on a SPAWNED PRODUCER FIBER, handing chunks
# to the consumer over a `Channel`. Cancellation works by closing the
# channel: the producer's parked `send` raises `Channel::ClosedError`,
# which unwinds through `exec` and closes the connection on the way
# out. `close` then does a single `Fiber.yield` to make that shutdown
# observable, on this stated assumption:
#
#     "One yield is enough: the producer's next scheduled step is
#      the raise."
#
# THAT IS THE ASSUMPTION UNDER TEST. It holds when the producer is
# parked on `@channel.send`. It does not hold when the producer is
# parked inside a SOCKET READ — closing a channel does not wake a
# fiber blocked on I/O. On Windows that read is an IOCP overlapped
# operation with a buffer handed to the kernel; if the process tears
# down with it outstanding, the completion writes into memory that is
# gone. An access violation, at an arbitrary later moment, with no
# exception to catch. Consistent with every symptom: Windows-only,
# racy, no test name, unaffected by rescuing anything.
#
# Case A cancels while the producer is parked on SEND (consumer took a
# chunk and stopped). Case B cancels while the producer is most likely
# parked on READ (consumer raises immediately on receiving a chunk,
# giving the producer time to go back to the socket).
#
# A is the passing "stream is abandoned" test.
# B is the crashing "raises mid-walk" test.
#
# Expected on Linux/macOS: both print DONE, exit 0.
# If the hypothesis holds on Windows: B crashes, exit 0xC0000005
# (-1073741819). It is a RACE, so run it several times before
# concluding it survived — see REPEATS below.
#
# Run:  crystal run --debug spec/scratch/win_stream_crash_repro.cr
# Then: echo $LASTEXITCODE   (PowerShell)

require "http/server"
require "http/client"

BODY_SIZE  = 40_000
CHUNK_SIZE =    512
REPEATS    =     20

record Head, status : Int32
record Chunk, size : Int32
record Done

alias Message = Head | Chunk | Done

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

# A cut-down HttpResponseStream: same producer-fiber-plus-channel
# shape, same cancellation strategy, none of the Adjutant machinery.
class MiniStream
  getter? closed = false

  def initialize(@client : HTTP::Client, request : HTTP::Request)
    @channel = Channel(Message).new
    @finished = false
    spawn produce(request)
  end

  def next_chunk : Chunk?
    return nil if @finished
    case message = @channel.receive
    when Chunk then message
    else
      @finished = true
      nil
    end
  rescue Channel::ClosedError
    @finished = true
    nil
  end

  # The method whose single `Fiber.yield` is the thing in question.
  def close : Nil
    return if @closed
    @closed = true
    @finished = true
    @channel.close
    Fiber.yield
  end

  private def produce(request : HTTP::Request) : Nil
    @client.exec(request) do |response|
      @channel.send(Head.new(response.status_code))
      if body = response.body_io?
        buffer = Bytes.new(CHUNK_SIZE)
        while (count = body.read(buffer)) > 0
          @channel.send(Chunk.new(count))
        end
      end
      @channel.send(Done.new)
    end
  rescue Channel::ClosedError
    # Expected: consumer abandoned the stream.
  rescue ex
    begin
      @channel.send(Done.new)
    rescue Channel::ClosedError
    end
  ensure
    @client.close rescue nil
  end
end

def open_stream(port : Int32) : MiniStream
  client = HTTP::Client.new("127.0.0.1", port)
  client.read_timeout = 5.seconds
  MiniStream.new(client, HTTP::Request.new("GET", "/"))
end

# --- Case A: cancel with the producer parked on SEND --------------
# The consumer pulls one chunk and stops. The producer has almost
# certainly filled the channel and is waiting to hand over the next
# one, so closing the channel wakes it immediately and the single
# `Fiber.yield` is sufficient.
with_server do |port|
  puts "A: cancel while producer is parked on send"
  REPEATS.times do
    stream = open_stream(port)
    stream.next_chunk # Head is consumed internally; this is a Chunk.
    stream.close
  end
  puts "A: DONE"
end

# --- Case B: cancel with the producer parked on READ --------------
# The consumer raises the instant a chunk arrives. The producer, freed
# by that receive, goes straight back to `body.read` — so the close
# below most likely lands while an overlapped read is outstanding, and
# the channel close cannot wake a fiber blocked on the socket.
#
# The `ensure` mirrors `interpreter.cr`'s `ensure ... close_all`:
# teardown running while a real exception unwinds.
with_server do |port|
  puts "B: cancel while producer is parked on read"
  REPEATS.times do |i|
    stream = open_stream(port)
    begin
      loop do
        break unless stream.next_chunk
        raise "boom"
      end
    rescue ex
      # Swallowed exactly as the spec's expect_raises would.
    ensure
      stream.close
    end
    puts "B: iteration #{i} survived" if i % 5 == 0
  end
  puts "B: DONE"
end

puts "ALL DONE"
