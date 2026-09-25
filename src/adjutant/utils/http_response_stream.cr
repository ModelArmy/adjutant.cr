require "http/client"

module Adjutant
  module Utils
    # Reads an HTTP response body in chunks, without buffering it and
    # without the caller seeing a fiber or channel:
    # `while chunk = stream.next_chunk`.
    #
    # `HTTP::Client#exec` either returns a buffered body or, in block
    # form, closes the connection when the block returns. So a producer
    # fiber keeps the block open and sends chunks over a channel to the
    # consumer.
    #
    # Knows nothing of budgets, labels or policy; the caller layers
    # those on. One producer and one consumer, on Crystal's
    # single-threaded scheduler; not thread-safe. It has no timeouts of
    # its own: a client without a read timeout, facing a server that
    # stalls mid-body, blocks both fibers indefinitely, so callers
    # should set one.
    class HttpResponseStream
      DEFAULT_CHUNK_SIZE = 64 * 1024

      # What crosses the channel.
      private record Head, status : Int32, headers : HTTP::Headers

      private record Chunk, bytes : Bytes

      private record Done

      # A failure on the producer fiber (an `IO::Error`, a timeout, a
      # dropped connection), sent across and re-raised on the
      # consumer's fiber. Otherwise a truncated body would look like a
      # complete one.
      private record Failed, error : Exception

      private alias Message = Head | Chunk | Done | Failed

      getter status : Int32
      getter headers : HTTP::Headers

      # Opens the response and waits for the status and headers, so a
      # caller can decide (follow, refuse, keep) before reading any
      # body.
      def self.open(client : HTTP::Client, request : HTTP::Request,
                    chunk_size : Int32 = DEFAULT_CHUNK_SIZE) : self
        new(client, request, chunk_size)
      end

      # Unbuffered, so the producer waits until the consumer pulls:
      # a fast server can't pile chunks up in memory.
      private def initialize(@client : HTTP::Client, request : HTTP::Request, @chunk_size : Int32)
        @channel = Channel(Message).new
        # Closed by the producer's `ensure` and never sent on, so a
        # receive returns once the producer has finished; `close`
        # waits on it.
        @done = Channel(Nil).new
        @closed = false
        @finished = false

        spawn produce(request)

        # The producer sends `Head` before any body, or `Failed`.
        case first = @channel.receive
        in Head
          @status = first.status
          @headers = first.headers
        in Failed
          # Nothing was opened, so nothing to tear down.
          @finished = true
          raise first.error
        in Chunk, Done
          # Unreachable. Raised rather than defaulting to status 0.
          @finished = true
          raise "HttpResponseStream: producer sent #{first.class} before Head"
        end
      end

      # The next chunk, or nil once the body is complete. Re-raises the
      # producer's failure here. Each chunk is newly allocated, since
      # the consumer may still hold one when the producer reads the
      # next.
      def next_chunk : Bytes?
        return if @finished

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
        # `close` ran while this fiber waited: the caller ended the
        # stream.
        @finished = true
        nil
      end

      # Ends the stream and releases the connection, however much was
      # read. Idempotent. Returns only once the producer has finished
      # and closed the client, so a caller counting open sockets
      # afterwards sees the true answer.
      #
      # Closing the channel makes a producer waiting on `send` raise
      # `Channel::ClosedError`, which unwinds out of the `exec` block
      # (closing the connection) and into `produce`'s `ensure`, the
      # same path as a finished stream. A producer blocked in a socket
      # read isn't woken by that; it stops at the next chunk or at the
      # client's read timeout, which is why `close` waits on `@done`
      # rather than yielding once.
      def close : Nil
        return if @closed
        @closed = true
        @finished = true
        @channel.close
        begin
          @done.receive
        rescue Channel::ClosedError
          # The producer finished.
        end
      end

      def closed? : Bool
        @closed
      end

      # The producer fiber's body, for the life of the stream.
      private def produce(request : HTTP::Request) : Nil
        @client.exec(request) do |response|
          @channel.send(Head.new(response.status_code, response.headers))
          pump(response)
        end
      rescue Channel::ClosedError
        # The consumer closed the stream. Caught, since an unhandled
        # exception on a spawned fiber ends the process.
      rescue ex
        # If the consumer has gone, this send raises; nobody needs the
        # failure then.
        begin
          @channel.send(Failed.new(ex))
        rescue Channel::ClosedError
        end
      ensure
        # Closed here, on the producer's fiber, once `exec` has
        # returned or unwound; closing it from the consumer's fiber
        # could race an in-flight read.
        @client.close rescue nil
        # Last: `close` waits on this, so everything it relies on must
        # happen above.
        @done.close
      end

      # Sends the body one chunk at a time. A response with no body
      # (204, HEAD) still sends `Done`, so `next_chunk` returns nil
      # rather than waiting forever.
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
