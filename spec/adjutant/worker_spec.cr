require "../spec_helper"
require "file_utils"

module Adjutant
  # Runs a Worker in a fiber as a Supervisor would: sends `request`
  # unless it is nil, answers each Ask with `decide` (under the ask's
  # own id plus `id_offset`), and reads until the worker closes its
  # end. Returns every message the worker sent and what it raised.
  private def self.worker_session(request : Protocol::SupervisorMessage?,
                                  decide : Protocol::DecisionRequest -> RiskFlowDecision = ->(_request : Protocol::DecisionRequest) { RiskFlowDecision::Allow },
                                  id_offset : Int32 = 0,
                                  &configure : Interpreter -> Nil) : {Array(Protocol::WorkerMessage), Exception?}
    worker_in, supervisor_out = IO.pipe
    supervisor_in, worker_out = IO.pipe
    failure = Channel(Exception?).new(1)
    spawn do
      begin
        Worker.new(worker_in, worker_out, &configure).serve
        failure.send(nil)
      rescue ex
        failure.send(ex)
      ensure
        worker_out.close
      end
    end
    if request
      Protocol.write(supervisor_out, request)
    else
      supervisor_out.close
    end
    messages = [] of Protocol::WorkerMessage
    while message = Protocol.read(supervisor_in, Protocol::WorkerMessage, limit: Protocol::WORKER_LINE_LIMIT)
      messages << message
      if message.is_a?(Protocol::Ask)
        Protocol.write(supervisor_out, Protocol::Answer.new(message.id + id_offset, decide.call(message.request)))
      end
    end
    {messages, failure.receive}
  end

  private def self.worker_run(source : String, policy : String = "risk_flow: none",
                              files : Hash(String, String) = {} of String => String) : Protocol::Run
    Protocol::Run.new(source, "task.rb", policy, files, ExecutionLimits.new, false)
  end

  # The outcome a session's last message carries, which must be a
  # Finished.
  private def self.worker_outcome(messages : Array(Protocol::WorkerMessage)) : Protocol::Outcome
    messages.last.as(Protocol::Finished).outcome
  end

  private def self.worker_tmpdir(&)
    path = File.join(Dir.tempdir, "adjutant-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir(path)
    begin
      yield path
    ensure
      FileUtils.rm_rf(path)
    end
  end

  # A policy that asks before `secret` is read, and grants reads in
  # `dir`.
  private def self.worker_asking_policy(dir : String, secret : String) : String
    <<-YAML
      grants:
        read: { roots: [#{dir.inspect}] }
      risk_flow:
        patterns:
          - { kind: file, pattern: #{secret.inspect}, priority: 10, sensitivity: high }
        rules:
          - { authority: read, sensitivity: high, action: ask }
        default: reject
      YAML
  end

  describe Worker do
    describe ".main" do
      it "returns at once unless asked to be a worker" do
        Worker.main(["--help"]) { raise "configured" }
        Worker.main([] of String)
      end
    end

    describe "#serve" do
      it "says hello first, with this build's protocol" do
        messages, failure = worker_session(worker_run("1")) { }
        failure.should be_nil
        hello = messages.first.should be_a(Protocol::Hello)
        hello.protocol.should eq Protocol::VERSION
      end

      it "returns quietly when the stream ends before a request" do
        messages, failure = worker_session(nil) { }
        failure.should be_nil
        messages.size.should eq 1
      end

      it "refuses an answer where a request should be" do
        _messages, failure = worker_session(Protocol::Answer.new(1, :allow)) { }
        failure.should be_a(Protocol::Violation)
        failure.try(&.message).should eq "expected a request, got answer"
      end
    end

    describe "a run" do
      it "sends standard output, then the result's inspect" do
        messages, failure = worker_session(worker_run(%(puts "hi"\nprint "there"\n[1, 2].size))) { }
        failure.should be_nil
        messages.compact_map(&.as?(Protocol::Output)).map(&.text).join.should eq "hi\nthere"
        worker_outcome(messages).should eq Protocol::Completed.new("2", false)
      end

      it "serves require from the request's files" do
        messages, _ = worker_session(worker_run(%(require "helper"\nHELPER), files: {"helper" => "HELPER = 5"})) { }
        worker_outcome(messages).should eq Protocol::Completed.new("5", false)
      end

      it "runs the host's configuration before the script" do
        configured = 0
        messages, _ = worker_session(worker_run("1")) { |_interp| configured += 1 }
        configured.should eq 1
        worker_outcome(messages).should be_a(Protocol::Completed)
      end

      # Scripts build long strings by doubling: `String#*` isn't
      # supported (SCOPE.md, Will Fix).
      it "splits long output into chunks, each within the limit" do
        messages, _ = worker_session(worker_run(%(s = "é"\n16.times { s = s + s }\nprint s))) { }
        chunks = messages.compact_map(&.as?(Protocol::Output)).map(&.text)
        chunks.size.should eq 2
        chunks.each(&.bytesize.should(be <= Worker::OUTPUT_CHUNK))
        chunks.join.should eq "é" * 65_536
      end

      it "cuts a long result, and says so" do
        messages, _ = worker_session(worker_run(%(s = "a"\n18.times { s = s + s }\ns))) { }
        completed = worker_outcome(messages).should be_a(Protocol::Completed)
        completed.truncated?.should be_true
        completed.value.bytesize.should eq Worker::RESULT_LIMIT
      end

      it "ends with Raised for an error the script didn't rescue" do
        messages, _ = worker_session(worker_run(%(raise "boom"))) { }
        raised = worker_outcome(messages).should be_a(Protocol::Raised)
        raised.rendered.should contain "boom"
      end

      it "ends with Raised, its diagnostic and rendering, for a parse error" do
        messages, _ = worker_session(worker_run("def")) { }
        raised = worker_outcome(messages).should be_a(Protocol::Raised)
        raised.diagnostic.should_not be_nil
        raised.rendered.should contain "task.rb"
      end

      it "ends with Raised for a policy that doesn't load, before any script" do
        messages, _ = worker_session(worker_run("1", policy: "risk_flow: none\nbogus: 1")) { }
        raised = worker_outcome(messages).should be_a(Protocol::Raised)
        raised.diagnostic.should be_nil
        raised.rendered.should contain "bogus"
      end

      it "ends with Fatal, after the audit record that explains it" do
        worker_tmpdir do |dir|
          outside = File.join(dir, "outside.txt")
          File.write(outside, "x")
          messages, _ = worker_session(worker_run(%(Legate.read(#{outside.inspect})))) { }
          fatal = worker_outcome(messages).should be_a(Protocol::Fatal)
          fatal.signal.should eq Protocol::FatalKind::Denied
          audit = messages[-2].should be_a(Protocol::Audit)
          audit.record.decision.should eq Protocol::AuditDecision::Denied
        end
      end

      it "asks the Supervisor and acts on its answer" do
        worker_tmpdir do |dir|
          secret = File.join(dir, "secret.txt")
          File.write(secret, "shh")
          source = %(begin\n  Legate.read(#{secret.inspect})\nrescue RiskFlowRejectedError\n  "refused"\nend)
          {RiskFlowDecision::Allow => %("shh"), RiskFlowDecision::Reject => %("refused")}.each do |decision, result|
            asked = [] of String
            decide = ->(request : Protocol::DecisionRequest) do
              asked << request.call_name
              decision
            end
            messages, failure = worker_session(worker_run(source, policy: worker_asking_policy(dir, secret)), decide) { }
            failure.should be_nil
            asked.should eq ["Legate.read"]
            worker_outcome(messages).as(Protocol::Completed).value.should start_with result
          end
        end
      end

      it "ends, past the script's rescue, when an answer names another ask" do
        worker_tmpdir do |dir|
          secret = File.join(dir, "secret.txt")
          File.write(secret, "shh")
          source = %(begin\n  Legate.read(#{secret.inspect})\nrescue Exception\n  "swallowed"\nend)
          messages, failure = worker_session(worker_run(source, policy: worker_asking_policy(dir, secret)), id_offset: 1) { }
          failure.should be_a(Protocol::Violation)
          failure.try(&.message).should eq "expected the answer to ask 1, got the answer to ask 2"
          messages.none?(Protocol::Finished).should be_true
        end
      end
    end

    describe "an assessment" do
      it "ends with an Assessment of what the script could do" do
        messages, failure = worker_session(Protocol::Assess.new(%(Legate.read("a")), "task.rb", "risk_flow: none")) { }
        failure.should be_nil
        assessed = messages.last.should be_a(Protocol::Assessed)
        assessment = assessed.outcome.should be_a(Protocol::Assessment)
        assessment.summary.effects.should contain Effect::ReadsFiles
        assessment.findings.should_not be_empty
      end

      it "ends with Raised for a script that doesn't parse" do
        messages, _ = worker_session(Protocol::Assess.new("def", "task.rb", "risk_flow: none")) { }
        assessed = messages.last.should be_a(Protocol::Assessed)
        assessed.outcome.should be_a(Protocol::Raised)
      end

      it "doesn't run the script" do
        messages, _ = worker_session(Protocol::Assess.new(%(puts "ran"), "task.rb", "risk_flow: none")) { }
        messages.none?(Protocol::Output).should be_true
      end
    end

    describe ".truncate" do
      it "cuts on a character boundary" do
        Worker.truncate("aé", 2).should eq({"a", true})
        Worker.truncate("aé", 3).should eq({"aé", false})
      end

      it "replaces invalid UTF-8" do
        Worker.truncate("a\xFFb", 10).should eq({"a\uFFFDb", false})
      end
    end

    describe ".each_chunk" do
      it "never splits a character" do
        chunks = [] of String
        Worker.each_chunk("aéééé", 4) { |chunk| chunks << chunk }
        chunks.should eq ["aé", "éé", "é"]
      end

      it "refuses a size that can't hold every character" do
        expect_raises(ArgumentError) { Worker.each_chunk("a", 3) { } }
      end
    end
  end
end
