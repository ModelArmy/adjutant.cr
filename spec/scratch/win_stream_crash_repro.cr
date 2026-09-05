# Windows crash repro, v5 — the last attempt before Windows is parked.
#
# ## What changed, and why v1-v4 could not have worked
#
# Four earlier versions varied the wrong things: whether the body was
# read synchronously, whether a producer fiber existed, how deep the
# unwind was, how many `ensure` frames it crossed. All survived.
#
# The one structure they never had is what Adjutant's VM puts in the
# unwind path. `VM#call_native` (vm.cr) wraps EVERY native call in a
# four-clause rescue chain that CATCHES AND RE-RAISES:
#
#     rescue ex : BlockBreakSignal   ex.value          # swallow
#     rescue ex : FatalSignal        raise ex          # re-raise
#     rescue ex : RuntimeError       raise ex          # re-raise
#     rescue ex                      raise Wrapped.new # translate
#
# So when a script raises inside a streamed walk, the exception is
# caught mid-unwind on a frame that also spans a fiber switch, and
# then thrown again. `FindAndUnlinkFrame` — which is where the process
# aborts — maintains MSVC's list of registered SEH frames and fails
# when the frame it unlinks is not the one it expects. Catch-and-
# rethrow manipulates that list; a plain `ensure` does not. v4's depth
# sweep was varying cleanup frames, which never re-register a handler.
#
# ## Also new: an EXTERNAL server
#
# `spec/scratch/external_server_crash_spec.cr` established that the
# crash does NOT need an in-process `HTTP::Server` — it crashes just
# the same against a static file server in another OS process. So
# there is no server fiber here at all, which removes a whole class of
# scheduling coincidence from the picture and makes this a cleaner
# thing to hand upstream if it fires.
#
# ## The four variants
#
#   none        no rescue chain at all — v4's shape, the control
#   reraise     catch and `raise ex` (VM's FatalSignal/RuntimeError path)
#   translate   catch and raise a NEW exception (VM's N001 path)
#   both        a translate frame inside a re-raise frame, as the VM
#               produces when a native call nests inside another
#
# Each runs at several nesting depths, because one re-raise frame may
# not be enough — the VM stacks one per native call in the chain.
#
# Expected on Linux/macOS: the whole table prints, exit 0.
# On Windows, if the hypothesis holds: the run stops partway and the
# last line printed names the variant and depth that died.
#
# ## Running it
#
#   python -m http.server 8099        # in a dir containing big.bin
#   ADJUTANT_EXTERNAL_PORT=8099 crystal run --debug win_stream_crash_repro.cr
#
# `big.bin` needs to be a few tens of KB so the body arrives in
# several chunks.

require "http/client"

CHUNK_SIZE = 8_192
REPEATS    =     8
DEPTHS     = [1, 3, 10]

PORT = (ENV["ADJUTANT_EXTERNAL_PORT"]? || "8099").to_i
PATH = ENV["ADJUTANT_EXTERNAL_PATH"]? || "/big.bin"

# Stands in for `Legate::FatalSignal`: a plain Exception, deliberately
# NOT a subclass of the type the middle clause matches, so the rescue
# chain below has to fall through more than one clause.
class SignalLike < Exception
end

class WrappedError < Exception
end

# The essential shape of `Utils::HttpResponseStream`: an HTTP read
# loop on a producer fiber, chunks over an unbuffered channel,
# cancelled by closing it.
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

  # The frame that spans the fiber switch AND stays on the stack while
  # the caller's block runs.
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
  rescue ex
    begin
      @channel.send(nil)
    rescue Channel::ClosedError
    end
  ensure
    @client.close rescue nil
  end
end

def open_stream : ChunkStream
  client = HTTP::Client.new("127.0.0.1", PORT)
  client.read_timeout = 5.seconds
  ChunkStream.new(client, HTTP::Request.new("GET", PATH, HTTP::Headers.new))
end

# `VM#call_native`'s rescue chain, reproduced in shape: several
# clauses, the matching one re-raising the SAME object unchanged.
def reraise_frame(&) : Nil
  yield
rescue ex : SignalLike
  raise ex
rescue ex : ArgumentError
  raise ex
rescue ex
  raise ex
end

# `VM#call_native`'s catch-all, which raises a NEW exception built
# from the old one rather than re-raising it — the N001 path.
def translate_frame(&) : Nil
  yield
rescue ex : SignalLike
  raise ex
rescue ex
  raise WrappedError.new(ex.message)
end

def plain_frame(&) : Nil
  yield
end

def nest(kind : Symbol, depth : Int32, &block : -> Nil) : Nil
  if depth <= 0
    block.call
  else
    inner = -> { nest(kind, depth - 1, &block) }
    case kind
    when :reraise   then reraise_frame { inner.call }
    when :translate then translate_frame { inner.call }
    when :both
      # A translate frame inside a re-raise frame, as the VM produces
      # when one native call nests inside another.
      reraise_frame { translate_frame { inner.call } }
    else plain_frame { inner.call }
    end
  end
end

def attempt(kind : Symbol, depth : Int32) : Nil
  stream = open_stream
  begin
    stream.walk do |chunk|
      nest(kind, depth) { raise "boom" }
    end
  rescue
    # Swallowed, as expect_raises would.
  ensure
    # Mirrors `interpreter.cr`'s `ensure ... open_sources.close_all`.
    stream.close
  end
end

# Fail early and clearly if the server is not up, rather than
# reporting a misleading survival.
begin
  probe = HTTP::Client.new("127.0.0.1", PORT)
  probe.read_timeout = 5.seconds
  response = probe.get(PATH)
  raise "unexpected status #{response.status_code}" unless response.status_code == 200
  probe.close
  puts "server ok on port #{PORT}#{PATH}"
rescue ex
  puts "CANNOT REACH SERVER on 127.0.0.1:#{PORT}#{PATH} — #{ex.message}"
  puts "Start one with: python -m http.server #{PORT}"
  exit 1
end

[:none, :reraise, :translate, :both].each do |kind|
  DEPTHS.each do |depth|
    print "#{kind.to_s.ljust(10)} depth #{depth.to_s.rjust(2)}: "
    STDOUT.flush
    REPEATS.times do
      attempt(kind, depth)
      print "."
      STDOUT.flush
    end
    puts " ok"
  end
end

puts "ALL DONE"
