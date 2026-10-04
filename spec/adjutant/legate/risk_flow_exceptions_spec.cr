require "../../spec_helper"
require "http/server"

private alias Handler = HTTP::Server::Context ->

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

# A handler answering 200 that records each request's `X-Api-Key`.
private def recording(received : Array(String?)) : Handler
  ->(context : HTTP::Server::Context) {
    received << context.request.headers["X-Api-Key"]?
    context.response.print("ok")
  }
end

private def with_env(values : Hash(String, String), &)
  values.each { |name, value| ENV[name] = value }
  begin
    yield
  ensure
    values.each_key { |name| ENV.delete(name) }
  end
end

private STRIPE_VAR = "ADJUTANT_SPEC_STRIPE_KEY"
private GITHUB_VAR = "ADJUTANT_SPEC_GITHUB_TOKEN"

module Adjutant
  # Both variables High; Net/High rejected, except `STRIPE_VAR`
  # reaching `allowed_port`; every other pair allowed, so reading the
  # variables isn't itself refused.
  private def self.stripe_policy(allowed_port : Int32,
                                 base : RiskFlowAction = RiskFlowAction::Reject) : RiskFlowPolicy
    RiskFlowPolicy.new(
      sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::Env, STRIPE_VAR, 10, Sensitivity::High),
        SensitivityPattern.new(ProvenanceKind::Env, GITHUB_VAR, 10, Sensitivity::High),
      ],
      risk_flow_rules: allow_unlisted([RiskFlowRule.new(Authority::Net, Sensitivity::High, base)]) + [
        RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow,
          origin: RiskFlowOrigin.new(ProvenanceKind::Env, STRIPE_VAR),
          subject: RiskFlowSubject.new("http://127.0.0.1:#{allowed_port}"), priority: 10),
      ],
    )
  end

  private def self.stripe_grants(ports : Array(Int32)) : Legate::Grants
    Legate::Grants.new(
      net_rules: ports.map { |port| Legate::NetRule.new(host: "127.0.0.1", scheme: "http", ports: [port], local: true) },
      net_methods: ["get"],
      ambient_env: [STRIPE_VAR, GITHUB_VAR],
      net_redirect_headers: ["X-Api-Key"],
    )
  end

  # Sends `key_expr` as `X-Api-Key` to `port`; "sent" or "rejected".
  private def self.send_api_key(interp : Interpreter, port : Int32, key_expr : String) : String
    interp.eval(<<-RUBY).as_string
      begin
        Legate.fetch("http://127.0.0.1:#{port}/", headers: {"X-Api-Key" => #{key_expr}})
        "sent"
      rescue RiskFlowRejectedError
        "rejected"
      end
      RUBY
  end

  describe "risk-flow exceptions at the sink's subject" do
    it "lets the excepted key reach its own host" do
      received = [] of String?
      with_env({STRIPE_VAR => "sk_live", GITHUB_VAR => "ghp_x"}) do
        with_server(recording(received)) do |port|
          interp, _ = make_interp(grants: stripe_grants([port]), risk_flow_policy: stripe_policy(port))
          send_api_key(interp, port, %(Legate.env("#{STRIPE_VAR}"))).should eq "sent"
          received.should eq ["sk_live"]
        end
      end
    end

    it "refuses the excepted key mixed with another secret, even at its own host" do
      received = [] of String?
      with_env({STRIPE_VAR => "sk_live", GITHUB_VAR => "ghp_x"}) do
        with_server(recording(received)) do |port|
          interp, _ = make_interp(grants: stripe_grants([port]), risk_flow_policy: stripe_policy(port))
          mixed = %(Legate.env("#{STRIPE_VAR}") + Legate.env("#{GITHUB_VAR}"))
          send_api_key(interp, port, mixed).should eq "rejected"
          received.should be_empty
        end
      end
    end

    it "refuses the excepted key at another granted host" do
      received = [] of String?
      with_env({STRIPE_VAR => "sk_live", GITHUB_VAR => "ghp_x"}) do
        with_server(recording(received)) do |allowed|
          with_server(recording(received)) do |other|
            interp, _ = make_interp(grants: stripe_grants([allowed, other]), risk_flow_policy: stripe_policy(allowed))
            send_api_key(interp, other, %(Legate.env("#{STRIPE_VAR}"))).should eq "rejected"
            received.should be_empty
          end
        end
      end
    end

    # Each hop is judged at its own host, so a redirect can't carry the
    # key past the one host its exception names.
    it "refuses the excepted key at a redirect's next host" do
      at_other = [] of String?
      with_env({STRIPE_VAR => "sk_live", GITHUB_VAR => "ghp_x"}) do
        with_server(recording(at_other)) do |other|
          at_allowed = [] of String?
          redirecting = ->(context : HTTP::Server::Context) {
            at_allowed << context.request.headers["X-Api-Key"]?
            context.response.status_code = 302
            context.response.headers["Location"] = "http://127.0.0.1:#{other}/"
          }
          with_server(redirecting) do |allowed|
            interp, _ = make_interp(grants: stripe_grants([allowed, other]), risk_flow_policy: stripe_policy(allowed))
            send_api_key(interp, allowed, %(Legate.env("#{STRIPE_VAR}"))).should eq "rejected"
            at_allowed.should eq ["sk_live"]
            at_other.should be_empty
          end
        end
      end
    end

    # Only what reaches a hop is checked there: a key the redirect
    # strips isn't sent, so it can't be refused.
    it "lets a redirect proceed to another host when it strips the key" do
      at_other = [] of String?
      with_env({STRIPE_VAR => "sk_live", GITHUB_VAR => "ghp_x"}) do
        with_server(recording(at_other)) do |other|
          at_allowed = [] of String?
          redirecting = ->(context : HTTP::Server::Context) {
            at_allowed << context.request.headers["X-Api-Key"]?
            context.response.status_code = 302
            context.response.headers["Location"] = "http://127.0.0.1:#{other}/"
          }
          with_server(redirecting) do |allowed|
            grants = Legate::Grants.new(
              net_rules: [allowed, other].map { |port| Legate::NetRule.new(host: "127.0.0.1", scheme: "http", ports: [port], local: true) },
              net_methods: ["get"],
              ambient_env: [STRIPE_VAR, GITHUB_VAR],
            )
            interp, _ = make_interp(grants: grants, risk_flow_policy: stripe_policy(allowed))
            send_api_key(interp, allowed, %(Legate.env("#{STRIPE_VAR}"))).should eq "sent"
            at_allowed.should eq ["sk_live"]
            at_other.should eq [nil]
          end
        end
      end
    end

    it "names the subject in the decision request an Ask raises" do
      subjects = [] of String?
      with_env({STRIPE_VAR => "sk_live", GITHUB_VAR => "ghp_x"}) do
        with_server(recording([] of String?)) do |allowed|
          with_server(recording([] of String?)) do |other|
            on_decision = ->(request : RiskFlowDecisionRequest) : RiskFlowDecision {
              subjects << request.subject
              RiskFlowDecision::Allow
            }
            interp, _ = make_interp(grants: stripe_grants([allowed, other]),
              risk_flow_policy: stripe_policy(allowed, base: RiskFlowAction::Ask),
              on_risk_flow_decision: on_decision)
            send_api_key(interp, other, %(Legate.env("#{STRIPE_VAR}"))).should eq "sent"
            subjects.should eq ["http://127.0.0.1:#{other}"]
          end
        end
      end
    end
  end
end
