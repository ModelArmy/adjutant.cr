require "../../spec_helper"
require "http/server"
require "file_utils"

private def with_tmpdir(&)
  path = File.join(Dir.tempdir, "adjutant-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

private alias Handler = HTTP::Server::Context ->

# A real loopback server rather than the Wiretap transcripts the
# buffered `fetch_spec.cr` uses.
#
# Two reasons. The streamed cases need a live connection (a replayed
# `IO::Memory` cannot exhibit a chunk arriving after a label was
# computed), and the redirect cases need each hop to authorize against
# a DIFFERENT host so the accumulated label is observably a join
# rather than the last hop's own. Doing both against one server keeps
# the file consistent instead of split across two harnesses.
private def with_ifc_server(handler : Handler, &)
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

module Adjutant
  # `net`'s IFC axis, which had no coverage at all before this file —
  # `sensitivity_labeling_spec.cr` covers every READ-grant verb, and
  # `risk_flow_propagation_spec.cr` covers `Response`'s own `.build`
  # propagation from Crystal, but nothing tied a REAL `Legate.fetch`
  # call to a labelled result. That gap mattered more than it looked:
  # `net` is the one grant whose whole purpose is moving data across a
  # trust boundary, so an unlabelled response is data that entered the
  # run untracked.
  #
  # `ProvenanceKind::Host` with an exact `scheme://host:port` subject —
  # the shape `Broker#authorize_net` builds. Port varies per spec
  # (the server binds an unused one), so patterns are built per run
  # rather than shared.
  private def self.host_policy(port : Int32, sensitivity : Sensitivity = Sensitivity::High) : RiskFlowPolicy
    RiskFlowPolicy.new(
      sensitivity_patterns: [
        SensitivityPattern.new(ProvenanceKind::Host, "http://127.0.0.1:#{port}", 10, sensitivity),
      ],
      risk_flow_rules: [RiskFlowRule.new(Authority::Net, sensitivity, RiskFlowAction::Allow)],
    )
  end

  private def self.loopback_grants(port : Int32, limits : Legate::Limits? = nil) : Legate::Grants
    Legate::Grants.new(
      net_rules: [Legate::NetRule.new(host: "127.0.0.1", scheme: "http", ports: [port], local: true)],
      net_methods: ["get", "post"],
      limits: limits || Legate::Limits.new,
    )
  end

  private def self.serving(body : String) : Handler
    ->(context : HTTP::Server::Context) { context.response.print(body) }
  end

  describe "Legate.fetch IFC labelling" do
    describe "buffered responses" do
      it "labels the body String" do
        with_ifc_server(serving("secret payload")) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/").body))
          result.label.should_not be_nil
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      it "labels the outer Response object" do
        with_ifc_server(serving("x")) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/")))
          result.label.should_not be_nil
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      it "labels header VALUES" do
        with_ifc_server(->(context : HTTP::Server::Context) {
          context.response.headers["X-Marker"] = "here"
          context.response.print("x")
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/").headers["x-marker"]))
          result.label.should_not be_nil
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      # Metadata, not extracted data — the same distinction
      # `risk_flow_propagation_spec.cr` already pins for `Stat#type`
      # and `Match#line_no`. A status code reveals nothing the script
      # did not already know it was asking for.
      it "leaves status and url unlabelled" do
        with_ifc_server(serving("x")) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          eval = interp.eval(<<-RUBY)
          response = Legate.fetch("http://127.0.0.1:#{port}/")
          [response.status, response.url]
          RUBY
          parts = eval.as_array.to_a
          parts[0].label.should be_nil
          parts[1].label.should be_nil
        end
      end

      it "propagates the body's label through #json" do
        with_ifc_server(->(context : HTTP::Server::Context) {
          context.response.headers["Content-Type"] = "application/json"
          context.response.print(%({"token":"abc","nested":{"deep":1}}))
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          eval = interp.eval(<<-RUBY)
          data = Legate.fetch("http://127.0.0.1:#{port}/").json
          [data["token"], data["nested"]["deep"]]
          RUBY
          parts = eval.as_array.to_a
          parts[0].label.not_nil!.sensitivity.should eq Sensitivity::High
          parts[1].label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end
    end

    describe "streamed responses" do
      it "labels each yielded Chunk" do
        with_ifc_server(serving("secret payload")) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.to_a.first))
          result.label.should_not be_nil
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      it "labels the outer Response object even though the stream handle itself is unlabelled" do
        with_ifc_server(serving("x")) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/", stream: true)))
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      # The label lives on the CHUNKS, not on the stream handle — the
      # same convention `Legate.bytes` already follows, and the reason
      # the response object's own label cannot be derived from its
      # body the way the buffered path's is.
      it "survives the stream ops" do
        with_ifc_server(serving("abcdefghij" * 40)) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          eval = interp.eval(<<-RUBY)
          stream = Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body
          stream.map { |c| c.to_s }.to_a.first
          RUBY
          eval.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      it "labels chunks taken by first(n) on an abandoned stream" do
        with_ifc_server(serving("y" * 40_000)) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.first(1).first))
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      # Chunks that arrived BEFORE a stream_limit stop are still data
      # that crossed the boundary, so they must still be labelled —
      # a refusal partway must not launder what already came through.
      #
      # THE NUMBERS MATTER, and an earlier version of this spec got
      # them wrong. Reads happen at `READ_CHUNK_SIZE` (64 KiB)
      # granularity, so a limit BELOW one chunk is breached by the
      # very first read and nothing is ever yielded — correct
      # behaviour, but it tests the opposite of what this case is
      # about. The limit here sits between one chunk and two, and the
      # body spans three, so exactly one chunk reaches the script
      # before the refusal.
      it "labels chunks yielded before a stream_limit refusal" do
        with_ifc_server(serving("q" * 200_000)) do |port|
          limits = Legate::Limits.new(stream_limit: 100_000_i64)
          interp, _ = make_interp(grants: loopback_grants(port, limits), risk_flow_policy: host_policy(port))
          eval = interp.eval(<<-RUBY)
          seen = []
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.each { |c| seen << c }
          rescue Legate::TooLarge
          end
          seen.first
          RUBY
          eval.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end
    end

    describe "joining and over-tainting" do
      # Joins rather than overwrites, matching the read verbs'
      # "combine, don't pick one side" rule. The URL itself is read
      # from a High-sensitivity file, so the request carries a taint
      # INTO a host whose own sensitivity is merely Elevated; the
      # result must reflect both, which in practice means the higher
      # of the two rather than whichever was applied last.
      it "joins an already-tainted URL argument with the host's own label" do
        with_ifc_server(serving("x")) do |port|
          with_tmpdir do |dir|
            url_file = File.join(dir, "endpoint.txt")
            File.write(url_file, "http://127.0.0.1:#{port}/")

            policy = RiskFlowPolicy.new(
              sensitivity_patterns: [
                SensitivityPattern.new(ProvenanceKind::Host, "http://127.0.0.1:#{port}", 10, Sensitivity::Elevated),
                SensitivityPattern.new(ProvenanceKind::File, url_file, 10, Sensitivity::High),
              ],
              risk_flow_rules: [
                RiskFlowRule.new(Authority::Net, Sensitivity::Elevated, RiskFlowAction::Allow),
                RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Allow),
                RiskFlowRule.new(Authority::Read, Sensitivity::High, RiskFlowAction::Allow),
              ],
            )
            grants = Legate::Grants.new(
              net_rules: [Legate::NetRule.new(host: "127.0.0.1", scheme: "http", ports: [port], local: true)],
              net_methods: ["get", "post"],
              read_roots: [dir],
            )
            interp, _ = make_interp(grants: grants, risk_flow_policy: policy)
            eval = interp.eval(<<-RUBY)
            url = Legate.read(#{url_file.inspect})
            Legate.fetch(url).body
            RUBY
            eval.label.not_nil!.sensitivity.should eq Sensitivity::High
          end
        end
      end

      # The fix must not over-taint: a host the policy has no opinion
      # on yields unlabelled data, buffered or streamed.
      it "leaves a buffered body from an unremarked host unlabelled" do
        with_ifc_server(serving("public")) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: RiskFlowPolicy.new)
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/").body))
          result.label.should be_nil
        end
      end

      it "leaves streamed chunks from an unremarked host unlabelled" do
        with_ifc_server(serving("public")) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: RiskFlowPolicy.new)
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/", stream: true).body.to_a.first))
          result.label.should be_nil
        end
      end
    end

    # THE CASE MOST LIKELY TO HIDE A BUG, and the reason it is written
    # out rather than assumed: `label` is reassigned per hop inside the
    # fetch loop via `RiskFlowLabel.join`, and the streaming path
    # threads that same `label` into an iterator constructed AFTER the
    # loop has finished. If the join were dropping earlier hops, the
    # body would carry only the final hop's label — and the final hop
    # is exactly the one a redirect chain can steer somewhere
    # innocuous.
    describe "redirect chains" do
      it "accumulates the label across hops on a buffered body" do
        with_ifc_server(->(context : HTTP::Server::Context) {
          if context.request.path == "/moved"
            context.response.status_code = 302
            context.response.headers["Location"] = "/final"
            context.response.print("notice")
          else
            context.response.print("final body")
          end
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/moved").body))
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      it "accumulates the label across hops on a streamed body" do
        with_ifc_server(->(context : HTTP::Server::Context) {
          if context.request.path == "/moved"
            context.response.status_code = 302
            context.response.headers["Location"] = "/final"
            context.response.print("notice")
          else
            context.response.print("final body")
          end
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          result = interp.eval(%(Legate.fetch("http://127.0.0.1:#{port}/moved", stream: true).body.to_a.first))
          result.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end

      # The label on `Legate::Redirect`'s own `location` — a redirect
      # target is data the remote host chose, so handing it back
      # unlabelled would be a laundering path straight out of the
      # error object.
      it "labels the location on a handed-back redirect" do
        with_ifc_server(->(context : HTTP::Server::Context) {
          context.response.status_code = 307
          context.response.headers["Location"] = "/elsewhere"
          context.response.print("moved")
        }) do |port|
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: host_policy(port))
          eval = interp.eval(<<-RUBY)
          target = nil
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", method: :post, body: "payload")
          rescue Legate::Redirect => e
            target = e.location
          end
          target
          RUBY
          eval.label.not_nil!.sensitivity.should eq Sensitivity::High
        end
      end
    end

    # A rejecting policy must stop the fetch before any data exists to
    # label — the gate and the labelling are two halves of the same
    # mechanism, and covering only the second would miss a fetch that
    # labels correctly but should never have run.
    describe "enforcement, not just labelling" do
      it "raises RiskFlowRejectedError and returns nothing when the policy rejects" do
        with_ifc_server(serving("secret")) do |port|
          policy = RiskFlowPolicy.new(
            sensitivity_patterns: [
              SensitivityPattern.new(ProvenanceKind::Host, "http://127.0.0.1:#{port}", 10, Sensitivity::High),
            ],
            risk_flow_rules: [RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Reject)],
          )
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: policy)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://127.0.0.1:#{port}/")
            "no error"
          rescue RiskFlowRejectedError
            "rejected"
          end
          RUBY
          eval.as_string.should eq "rejected"
        end
      end

      it "rejects a streamed fetch the same way" do
        with_ifc_server(serving("secret")) do |port|
          policy = RiskFlowPolicy.new(
            sensitivity_patterns: [
              SensitivityPattern.new(ProvenanceKind::Host, "http://127.0.0.1:#{port}", 10, Sensitivity::High),
            ],
            risk_flow_rules: [RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Reject)],
          )
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: policy)
          eval = interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", stream: true)
            "no error"
          rescue RiskFlowRejectedError
            "rejected"
          end
          RUBY
          eval.as_string.should eq "rejected"
        end
      end

      # A rejected fetch must leave no connection behind either.
      it "registers no open source when a streamed fetch is rejected" do
        with_ifc_server(serving("secret")) do |port|
          policy = RiskFlowPolicy.new(
            sensitivity_patterns: [
              SensitivityPattern.new(ProvenanceKind::Host, "http://127.0.0.1:#{port}", 10, Sensitivity::High),
            ],
            risk_flow_rules: [RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Reject)],
          )
          interp, _ = make_interp(grants: loopback_grants(port), risk_flow_policy: policy)
          interp.eval(<<-RUBY)
          begin
            Legate.fetch("http://127.0.0.1:#{port}/", stream: true)
          rescue RiskFlowRejectedError
          end
          RUBY
          interp.broker.open_sources.size.should eq 0
        end
      end
    end
  end
end
