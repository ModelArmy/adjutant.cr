require "http/client"

module Adjutant
  module Utils
    # Reads an HTTP response body in chunks, without buffering the
    # whole thing and without the caller ever seeing a fiber or a
    # channel.
    #
    # WHY THIS EXISTS AT ALL. Crystal's `HTTP::Client#exec` comes in
    # two forms and neither one does what streaming needs on its own:
    #
    #   - `exec(request)` returns a response whose body is already a
    #     fully-read String. It buffers, which is the thing being
    #     avoided.
    #   - `exec(request) { |response| ... }` exposes an unconsumed
    #     `response.body_io`, but closes the connection the moment the
    #     block returns — so the body cannot outlive the call.
    #
    # The block form is the only one with a live `body_io`, so the
    # block has to STAY OPEN for as long as the caller wants chunks.
    # That means the reading has to happen on its own fiber, with the
    # consumer pulling from the other end, and it means somebody has
    # to own the shutdown handshake. All of that is here, so that a
    # caller can write `while chunk = stream.next_chunk` and think
    # about nothing else.
    #
    # DELIBERATELY KNOWS NOTHING ABOUT ITS CALLER. No budgets, no
    # labels, no error classes, no policy — it speaks HTTP and fibers
    # and nothing else. The concurrency lives here with no policy in
    # it; the policy lives in the caller with no concurrency in it,
    # which is what makes each half testable on its own.
    #
    # Not thread-safe, and not intended to be: one producer fiber and
    # one consumer, on Crystal's default single-threaded scheduler.
    #
    # HOLDS NO TIMEOUTS OF ITS OWN, deliberately — it inherits
    # whatever `connect_timeout`/`read_timeout` the client was given,
    # so timeouts are configured in one place rather than two that can
    # disagree. The consequence is worth stating plainly: a client
    # with NO read timeout, pointed at a server that stalls mid-body
    # or promises more bytes than it sends, parks the producer in
    # `read` indefinitely and the consumer behind it. Nothing here
    # will break that deadlock, because nothing here knows how long is
    # too long. Callers should set a read timeout.
    class HttpResponseStream
      DEFAULT_CHUNK_SIZE = 64 * 1024

      # What crosses the channel. Four cases rather than just
      # "chunk or nil", because two of them carry information that is
      # otherwise lost.
      private record Head, status : Int32, headers : HTTP::Headers

      private record Chunk, bytes : Bytes

      private record Done

      # THE IMPORTANT ONE. A mid-stream `IO::Error`, a read timeout, a
      # connection dropped by the peer — all happen on the PRODUCER
      # fiber, where nothing is listening. A fiber that simply dies
      # leaves the consumer seeing a clean end-of-stream, so a
      # truncated download would look exactly like a complete one.
      # That is silent data loss, and it is the worst outcome
      # available here. So failures are sent across explicitly and
      # re-raised on the consumer's own fiber, where the caller's
      # own `begin`/`rescue` can actually see them.
      private record Failed, error : Exception

      private alias Message = Head | Chunk | Done | Failed

      getter status : Int32
      getter headers : HTTP::Headers

      # Opens the response and blocks until the status and headers
      # have arrived, so both are readable before the first chunk is
      # pulled — callers routinely need to decide what to do (follow,
      # refuse, hand back) based on the status alone, without
      # committing to reading a body.
      def self.open(client : HTTP::Client, request : HTTP::Request,
                    chunk_size : Int32 = DEFAULT_CHUNK_SIZE) : self
        new(client, request, chunk_size)
      end

      # UNBUFFERED CHANNEL, deliberately (capacity zero). The producer
      # parks on `send` until the consumer actually pulls, which gives
      # backpressure for free: a fast server cannot pile up chunks in
      # memory behind a slow consumer. A buffered channel here would
      # quietly reintroduce the buffering this class exists to avoid,
      # bounded by the capacity rather than by the response size — but
      # unbounded in the only sense that matters, since the caller
      # chose streaming precisely because it does not know how big the
      # body is.
      private def initialize(@client : HTTP::Client, request : HTTP::Request, @chunk_size : Int32)
        @channel = Channel(Message).new
        @closed = false
        @finished = false

        spawn produce(request)

        # The first message is always a `Head` or a `Failed` — the
        # producer sends `Head` before reading a single byte of body.
        case first = @channel.receive
        in Head
          @status = first.status
          @headers = first.headers
        in Failed
          # Nothing was ever opened, so there is nothing to tear down
          # beyond what the producer's own ensure already did.
          @finished = true
          raise first.error
        in Chunk, Done
          # Unreachable: `produce` sends `Head` first or `Failed`.
          # Stated as a real error rather than left to a nil status,
          # because a silent default here would be a bug that only
          # showed up as a mysterious zero status much later.
          @finished = true
          raise "HttpResponseStream: producer sent #{first.class} before Head"
        end
      end

      # The next chunk of body, or `nil` once the body is complete.
      #
      # Raises whatever the producer hit, on the CONSUMER's fiber —
      # see `Failed`. A caller that wants `IO::Error` turned into
      # something domain-specific wraps this call; that translation is
      # deliberately not done here.
      #
      # Each chunk is a FRESHLY ALLOCATED `Bytes`. Reusing one buffer
      # the way a single-fiber reader can (`read` into it, copy out,
      # repeat) is unsafe once the reader and the consumer are
      # different fibers: the consumer may still be holding chunk N
      # when the producer overwrites it with N+1. The allocation is
      # the price of the fiber boundary, and it is not optional.
      def next_chunk : Bytes?
        return nil if @finished

        case message = @channel.receive
        in Chunk
          message.bytes
        in Done
          @finished = true
          nil
        in Failed
          @finished = true
          raise message.error
        in Head
          @finished = true
          raise "HttpResponseStream: producer sent a second Head"
        end
      rescue Channel::ClosedError
        # `close` ran while this fiber was parked waiting. Not an
        # error: the caller asked for the stream to end.
        @finished = true
        nil
      end

      # Ends the stream and releases the connection. Idempotent, and
      # safe to call whether the body was fully read, partly read, or
      # never read at all.
      #
      # HOW CANCELLATION WORKS, since it is not obvious. Closing the
      # channel makes the producer's parked `send` raise
      # `Channel::ClosedError` inside the producer fiber. That
      # propagates out of the read loop, out of the `exec` block —
      # which closes the connection on its way, exactly as it would on
      # a normal return — and into `produce`'s own `ensure`. So an
      # abandoned stream and a completed one converge on the SAME
      # teardown path, rather than cancellation needing machinery of
      # its own.
      #
      # The `Fiber.yield` is what makes that shutdown observable to
      # the caller rather than merely eventual. Crystal's default
      # scheduler is cooperative, so without it this method could
      # return while the producer is still parked, having not yet
      # noticed the close — and a caller that immediately asserts the
      # connection is closed (or an embedder tearing down a run and
      # then counting open sockets) would see a stale answer. One
      # yield is enough: the producer's next scheduled step is the
      # raise.
      def close : Nil
        return if @closed
        @closed = true
        @finished = true
        @channel.close
        Fiber.yield
      end

      def closed? : Bool
        @closed
      end

      # Runs on the producer fiber for the whole life of the stream.
      private def produce(request : HTTP::Request) : Nil
        @client.exec(request) do |response|
          @channel.send(Head.new(response.status_code, response.headers))
          pump(response)
        end
      rescue Channel::ClosedError
        # The consumer closed the stream. The expected way an
        # abandoned stream ends, not a failure — and deliberately
        # caught here rather than being allowed to escape, since an
        # unhandled exception on a spawned fiber takes the whole
        # process down.
      rescue ex
        # Best effort: if the consumer has already gone away the
        # channel is closed and this send raises, which is fine —
        # there is nobody left who needed to hear about it.
        begin
          @channel.send(Failed.new(ex))
        rescue Channel::ClosedError
        end
      ensure
        # Closing the client here, on the producer's own fiber, rather
        # than in `close` on the consumer's: `exec` may still be
        # mid-read when cancellation arrives, and closing a client out
        # from under an in-flight read from another fiber is a race.
        # By the time this line runs, `exec` has returned or unwound,
        # so the connection is genuinely idle.
        @client.close rescue nil
      end

      # Reads the body and sends it on, one chunk at a time.
      #
      # A response with no `body_io` (a 204, a HEAD, anything the
      # client already decided has no body) still sends `Done`, so the
      # consumer's `next_chunk` returns nil rather than parking
      # forever on a channel nobody will ever send to.
      private def pump(response : HTTP::Client::Response) : Nil
        io = response.body_io?
        unless io
          body = response.body || ""
          @channel.send(Chunk.new(body.to_slice)) unless body.empty?
          @channel.send(Done.new)
          return
        end

        loop do
          buffer = Bytes.new(@chunk_size)
          read = io.read(buffer)
          break if read == 0
          @channel.send(Chunk.new(buffer[0, read]))
        end

        @channel.send(Done.new)
      end
    end
  end
end
