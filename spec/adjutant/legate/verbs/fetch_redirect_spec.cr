require "../../../spec_helper"
require "http/server"

private alias Handler = HTTP::Server::Context ->

# Real loopback servers, as in `fetch_stream_spec.cr`: what is under
# test is which headers reach a second server, which a transcript
# can't show. Two ports on 127.0.0.1 are two origins.
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

# Answers with the credential headers it received, then a custom
# header, then one always sent past a redirect, `|`-separated.
private ECHO = ->(context : HTTP::Server::Context) {
  h = context.request.headers
  context.response.print([h["Authorization"]?, h["Cookie"]?, h["Proxy-Authorization"]?, h["X-Trace"]?, h["Accept"]?].map(&.to_s).join("|"))
}

# Redirects `/start` to `url` and echoes everything else.
private def redirect_to(url : String) : Handler
  ->(context : HTTP::Server::Context) {
    if context.request.path == "/start"
      context.response.status_code = 302
      context.response.headers["Location"] = url
    else
      ECHO.call(context)
    end
  }
end

private def loopback_grants(ports : Array(Int32), redirect_headers = [] of String) : Adjutant::Legate::Grants
  Adjutant::Legate::Grants.new(
    net_rules: [Adjutant::Legate::NetRule.new(host: "127.0.0.1", scheme: "http", ports: ports, local: true)],
    net_methods: ["get"],
    net_redirect_headers: redirect_headers,
  )
end

private HEADERS = %({"Authorization" => "Bearer k", "Cookie" => "s=1", "Proxy-Authorization" => "Basic p", "X-Trace" => "t", "Accept" => "text/plain"})

# A script fetching `url` with `HEADERS` and returning the body as a
# String, streamed or not.
private def fetch_script(url : String, stream : Bool) : String
  if stream
    <<-RUBY
    parts = []
    Legate.fetch("#{url}", headers: #{HEADERS}, stream: true).body.each { |c| parts << c.to_s }
    parts.join
    RUBY
  else
    %(Legate.fetch("#{url}", headers: #{HEADERS}).body)
  end
end

module Adjutant
  describe "Legate.fetch headers across redirects" do
    {false, true}.each do |stream|
      suffix = stream ? " (stream: true)" : ""

      it "keeps only the default headers when a redirect changes origin#{suffix}" do
        with_server(ECHO) do |second|
          with_server(redirect_to("http://127.0.0.1:#{second}/echo")) do |first|
            interp, _ = make_interp(grants: loopback_grants([first, second]))
            eval = interp.eval(fetch_script("http://127.0.0.1:#{first}/start", stream))
            eval.as_string.should eq "||||text/plain"
          end
        end
      end

      it "keeps every header on a same-origin redirect#{suffix}" do
        with_server(redirect_to("/echo")) do |port|
          interp, _ = make_interp(grants: loopback_grants([port]))
          eval = interp.eval(fetch_script("http://127.0.0.1:#{port}/start", stream))
          eval.as_string.should eq "Bearer k|s=1|Basic p|t|text/plain"
        end
      end
    end

    it "adds the headers the grants name to the defaults, matched case-insensitively" do
      with_server(ECHO) do |second|
        with_server(redirect_to("http://127.0.0.1:#{second}/echo")) do |first|
          interp, _ = make_interp(grants: loopback_grants([first, second], ["x-TRACE"]))
          eval = interp.eval(fetch_script("http://127.0.0.1:#{first}/start", false))
          eval.as_string.should eq "|||t|text/plain"
        end
      end
    end

    # Once dropped, headers stay dropped: a hop back to the first
    # origin was chosen by the second server.
    it "doesn't restore headers when a later redirect returns to the first origin" do
      first_port = 0
      bounce = ->(context : HTTP::Server::Context) {
        context.response.status_code = 302
        context.response.headers["Location"] = "http://127.0.0.1:#{first_port}/echo"
      }
      with_server(bounce) do |second|
        with_server(redirect_to("http://127.0.0.1:#{second}/bounce")) do |first|
          first_port = first
          interp, _ = make_interp(grants: loopback_grants([first, second]))
          eval = interp.eval(fetch_script("http://127.0.0.1:#{first}/start", false))
          eval.as_string.should eq "||||text/plain"
        end
      end
    end
  end
end
