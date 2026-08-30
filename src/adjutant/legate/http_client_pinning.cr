require "http/client"
require "openssl"

# Address pinning for `Legate.fetch`, satisfying §8.2's third
# requirement: resolve the hostname, check EVERY resulting address,
# then **pin the chosen address for the connection**.
#
# WHY A REOPENED CLASS AND NOT A SUBCLASS. The obvious implementation
# is `class PinnedClient < HTTP::Client` overriding `io`. It must not
# be done that way: the record/replay harness used in the specs
# installs its interception by reopening `HTTP::Client` and patching
# `exec`, and only a receiver whose type is literally `HTTP::Client`
# is reliably intercepted. A subclassed receiver reaches the real
# `exec` and opens a real connection, so every replayed spec silently
# starts using the network. Keeping the receiver's type exact removes
# the question rather than answering it — an answer would depend on
# how Crystal resolves a reopened method for a subclass receiver,
# which is not something to stake offline CI on.
#
# The cost is a stdlib monkey patch, which is not free. It is the same
# technique the harness itself uses on the same class, it is additive
# (a new property plus one overridden private method that defers to
# `previous_def` whenever the property is unset), and it is confined
# to this file so there is exactly one place to look.
#
# Three properties the pinning preserves, each load-bearing:
#
#   - **TLS still verifies against the HOSTNAME.** `@host` is
#     untouched, so SNI and certificate verification use the real name
#     (`hostname: @host.rchop('.')`, exactly as the original does).
#     Pinning changes where the packets go, not who the certificate
#     must belong to — a pinned connection to an attacker's address
#     still fails the handshake.
#   - **`#host`, `#port`, `#tls?` and the `Host` header are
#     unchanged**, since only the socket's destination differs. The
#     record/replay harness derives a transcript's identity from those
#     accessors, so transcripts stay keyed on `https://example.com/path`
#     rather than on whichever IP the resolver returned on recording
#     day. No change to the harness was needed.
#   - **Socket creation stays LAZY.** `io` runs on the first request,
#     not at construction, and the harness intercepts `exec` ahead of
#     the real call — so a replayed spec opens no socket at all.
#     Building the connection eagerly and handing `HTTP::Client` a
#     ready-made `IO` (the other obvious route to pinning) would break
#     that, and with it every offline test run.
#
# NOT independently verified against a live toolchain: the override
# mirrors `HTTP::Client#io` as published, including the
# `without_openssl` guard and the TCP-socket cleanup on a failed
# handshake. If a future Crystal changes that method's shape, this
# diverges from it silently rather than failing to compile — worth
# re-reading on any compiler upgrade, and the reason the body below is
# a faithful copy rather than a cleverer rewrite.
class HTTP::Client
  # When set, the TCP connection goes to this literal address instead
  # of resolving `@host` a second time. A numeric address needs no DNS
  # query to become a socket, which is the entire point: without it,
  # the stack resolves the name AGAIN after `Legate.fetch` has already
  # vetted the answer, and a DNS rebinding attack can return a benign
  # address the first time and `169.254.169.254` the second.
  property adjutant_pinned_address : String?

  private def io
    pinned = @adjutant_pinned_address
    # Untouched behaviour for every other caller in the process. The
    # patch is inert unless `Legate.fetch` has explicitly opted in.
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
          # Don't leak the TCP socket when the TLS handshake fails —
          # the original's own behaviour, kept deliberately.
          socket.close
          raise exc
        end
      end
    {% end %}

    @io = connection
  end
end
