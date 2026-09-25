require "http/client"
require "openssl"

# Address pinning for `Legate.fetch` (LEGATE.md §8.2): once fetch has
# resolved a hostname and checked every address, the connection goes to
# the chosen address, not to a second resolution that DNS rebinding
# could answer differently.
#
# A reopening of HTTP::Client rather than a subclass: the specs'
# record/replay harness patches `HTTP::Client#exec` by reopening the
# class, and only a receiver of exactly that type is reliably
# intercepted, so a subclass would let replayed specs reach the network.
#
# The override must keep three properties:
#
#   - TLS verifies against the hostname: `@host` is unchanged, so SNI
#     and the certificate check use the real name, and a connection
#     pinned to the wrong address fails the handshake.
#   - `#host`, `#port`, `#tls?` and the Host header are unchanged, so
#     replay transcripts stay keyed on the URL, not the address.
#   - The socket opens lazily, on the first request, so a replayed spec
#     opens none.
#
# The body copies `HTTP::Client#io` as published, including the
# `without_openssl` guard and closing the TCP socket when the handshake
# fails. A Crystal release that changes that method won't break the
# build, so re-read it on every compiler upgrade.
class HTTP::Client
  # When set, the connection goes to this literal address rather than
  # resolving `@host` again.
  property adjutant_pinned_address : String?

  private def io
    pinned = @adjutant_pinned_address
    # Unchanged for every caller that hasn't set a pinned address.
    return previous_def unless pinned

    existing = @io
    return existing if existing
    unless @reconnect
      raise "This HTTP::Client cannot be reconnected"
    end

    socket = TCPSocket.new pinned, @port, @dns_timeout, @connect_timeout
    socket.read_timeout = @read_timeout if @read_timeout
    socket.write_timeout = @write_timeout if @write_timeout
    socket.sync = false

    connection : IO = socket
    {% if !flag?(:without_openssl) %}
      if tls = @tls
        begin
          connection = OpenSSL::SSL::Socket::Client.new(
            socket, context: tls, sync_close: true, hostname: @host.rchop('.'))
        rescue exc
          # Closes the TCP socket when the TLS handshake fails, as the
          # original does.
          socket.close
          raise exc
        end
      end
    {% end %}

    @io = connection
  end
end
