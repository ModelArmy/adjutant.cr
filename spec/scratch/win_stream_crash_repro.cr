# Windows crash repro, v4. Uses only Crystal's stdlib — no Adjutant at
# all, so a maintainer can run it directly.
#
# ## The crash being chased
#
# On Windows, `spec/adjutant/legate/verbs/fetch_stream_spec.cr`'s
# "closes the connection when the script raises mid-walk" terminates
# the process with 0xC0000409 (fail-fast, FATAL_APP_EXIT). Both
# Crystal 1.20 and latest. The dump's faulting stack:
#
#     ucrtbase!abort
#     VCRUNTIME140!FindAndUnlinkFrame        <-- aborts here
#     VCRUNTIME140!_C_specific_handler
#     ntdll!RtlUnwindEx
#     ...
#     KERNELBASE!RaiseException
#     <application frames>
#
# `FindAndUnlinkFrame` maintains MSVC's linked list of registered SEH
# frames and aborts when the frame it unlinks is not the one it
# expects. So this is an integrity CHECK failing during unwinding, not
# a memory error — which is why nothing in-process can catch it.
#
# ## What is already known, from bisection against the real suite
#
#   VM   socket-backed   unwinding   result
#   ---  -------------   ---------   ------
#   yes  no (file)       yes         passes
#   no   yes             yes         passes   <-- repro v3, case C
#   yes  yes             no (break)  passes
#   yes  yes             yes         DIES
#
# All three ingredients necessary, none sufficient. Body size and the
# producer fiber's parked state make no difference.
#
# ## What v3 got wrong, and what v4 changes
#
# v3 called `next_chunk`, let it RETURN, and then raised. So the frame
# that spanned the fiber switch had already popped, and the unwind
# never travelled through it. The real code raises from inside a block
# that a walk loop yields to, while that loop's frame — which parked
# on a channel receive and switched to the producer fiber — is still
# on the stack below.
#
# v4 mirrors that: `walk` loops, receives (switching fibers), and
# yields; the raise happens in the yielded block and unwinds back
# through `walk`.
#
# ## Why this sweeps rather than asserts
#
# Two candidates remain for why the real test dies where v3 lived:
# how DEEP the unwind is, and how many `ensure`/`rescue` frames it
# crosses. Rather than pick one, this varies both and reports which
# combination dies. On Windows the expectation is that a run stops
# mid-table; the last line printed names the crashing configuration.
#
# Expected on Linux/macOS: the whole table prints, then ALL DONE,
# exit 0.
#
# Run:   crystal run --debug win_stream_crash_repro.cr
# Then:  echo $LASTEXITCODE     (PowerShell)

require "http/server"
require "http/client"

BODY_SIZE  = 40_000
CHUNK_SIZE =  8_192
REPEATS    =     10

DEPTHS = [0, 1, 5, 20, 50]

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

# The essential shape of `Utils::HttpResponseStream`: an HTTP read
# loop on a spawned producer fiber, handing chunks to the consumer
# over an UNBUFFERED channel, cancelled by closing that channel.
class ChunkStream
  def initialize(@client : HTTP::Client, request : HTTP::Request)
    @channel = Channel(Bytes?).new
    @closed = false
    spawn produce(request)
  end

  def next_chunk : Bytes?
    @channel.receive
  rescue Channel::ClosedError
    nil
  end

  # THE FRAME THAT MATTERS. It parks on `receive`, which switches to
  # the producer fiber, then yields to the caller's block while still
  # on the stack. An exception raised in that block unwinds back
  # through this frame — the one that spanned the fiber switch.
  def walk(&) : Nil
    loop do
      chunk = next_chunk
      break unless chunk
      yield chunk
    end
  end

  def close : Nil
    return if @closed
    @closed = true
    @channel.close
    Fiber.yield
  end

  private def produce(request : HTTP::Request) : Nil
    @client.exec(request) do |response|
      if body = response.body_io?
        buffer = Bytes.new(CHUNK_SIZE)
        while (count = body.read(buffer)) > 0
          @channel.send(buffer[0, count])
        end
      end
      @channel.send(nil)
    end
  rescue Channel::ClosedError
    # Consumer abandoned the stream.
  rescue ex
    begin
      @channel.send(nil)
    rescue Channel::ClosedError
    end
  ensure
    @client.close rescue nil
  end
end

def open_stream(port : Int32) : ChunkStream
  client = HTTP::Client.new("127.0.0.1", port)
  client.read_timeout = 5.seconds
  ChunkStream.new(client, HTTP::Request.new("GET", "/", HTTP::Headers.new))
end

# Adds `depth` frames between the raise and the rescue, each carrying
# an `ensure` so the unwind must run cleanup at every level. This is
# what stands in for the VM's own nested frames in the real failure.
def nested(depth : Int32, &block : -> Nil) : Nil
  if depth <= 0
    block.call
  else
    begin
      nested(depth - 1, &block)
    ensure
      # Deliberately non-empty: an ensure the optimiser cannot drop.
      Fiber.current.name
    end
  end
end

def attempt(port : Int32, depth : Int32) : Nil
  stream = open_stream(port)
  begin
    stream.walk do |chunk|
      nested(depth) { raise "boom" }
    end
  rescue
    # Swallowed, as the spec's expect_raises would.
  ensure
    # Mirrors `interpreter.cr`'s `ensure ... open_sources.close_all`.
    stream.close
  end
end

with_server do |port|
  DEPTHS.each do |depth|
    print "depth #{depth.to_s.rjust(2)}: "
    STDOUT.flush
    REPEATS.times do
      attempt(port, depth)
      print "."
      STDOUT.flush
    end
    puts " ok"
  end
end

puts "ALL DONE"
