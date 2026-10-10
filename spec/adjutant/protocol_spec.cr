require "../spec_helper"

module Adjutant
  private def self.protocol_round_trip(message : Protocol::Message, klass : T.class) : T? forall T
    io = IO::Memory.new
    Protocol.write(io, message)
    io.rewind
    Protocol.read(io, klass, limit: 1 << 20)
  end

  private def self.protocol_refuses(line : String, klass : T.class, message : Regex, limit : Int32 = 1 << 20) : Nil forall T
    expect_raises(Protocol::Violation, message) do
      Protocol.read(IO::Memory.new(line), klass, limit: limit)
    end
  end

  describe Protocol do
    describe "round trips" do
      it "a Hello, carrying this build's protocol and version" do
        hello = protocol_round_trip(Protocol::Hello.new, Protocol::WorkerMessage).should be_a(Protocol::Hello)
        hello.protocol.should eq Protocol::VERSION
        hello.adjutant.should eq Adjutant::VERSION
      end

      it "an Output" do
        output = protocol_round_trip(Protocol::Output.new("a\nb \u{1F600}"), Protocol::WorkerMessage).should be_a(Protocol::Output)
        output.text.should eq "a\nb \u{1F600}"
      end

      it "a LogEntry" do
        entry = protocol_round_trip(Protocol::LogEntry.new(:warn, "adjutant.legate", "denied"), Protocol::WorkerMessage)
          .should be_a(Protocol::LogEntry)
        entry.severity.should eq ::Log::Severity::Warn
        entry.source.should eq "adjutant.legate"
        entry.message.should eq "denied"
      end

      it "an Assess" do
        assess = protocol_round_trip(Protocol::Assess.new("puts 1", "task.rb", "risk_flow: none"), Protocol::SupervisorMessage)
          .should be_a(Protocol::Assess)
        assess.source.should eq "puts 1"
        assess.filename.should eq "task.rb"
        assess.policy.should eq "risk_flow: none"
      end

      it "a Run, with its files and limits" do
        limits = ExecutionLimits.new(instruction_limit: 500_000_u64, call_depth_limit: 64)
        sent = Protocol::Run.new("require \"helper\"", "task.rb", "risk_flow: none", {"helper" => "1"}, limits, true)
        run = protocol_round_trip(sent, Protocol::SupervisorMessage).should be_a(Protocol::Run)
        run.files.should eq({"helper" => "1"})
        run.limits.instruction_limit.should eq 500_000_u64
        run.limits.call_depth_limit.should eq 64
        run.risk_flow_tracking?.should be_true
      end

      it "an Answer" do
        answer = protocol_round_trip(Protocol::Answer.new(3, :reject), Protocol::SupervisorMessage).should be_a(Protocol::Answer)
        answer.id.should eq 3
        answer.decision.should eq RiskFlowDecision::Reject
      end
    end

    describe "framing" do
      it "writes one line per message" do
        io = IO::Memory.new
        Protocol.write(io, Protocol::Output.new("a\nb"))
        Protocol.write(io, Protocol::Output.new("c"))
        io.to_s.lines.size.should eq 2
      end

      it "reads messages in order, then nil at the end of the stream" do
        io = IO::Memory.new
        Protocol.write(io, Protocol::Output.new("first"))
        Protocol.write(io, Protocol::Output.new("second"))
        io.rewind
        Protocol.read(io, Protocol::WorkerMessage, limit: 1024).should be_a(Protocol::Output)
        Protocol.read(io, Protocol::WorkerMessage, limit: 1024).as(Protocol::Output).text.should eq "second"
        Protocol.read(io, Protocol::WorkerMessage, limit: 1024).should be_nil
      end

      it "accepts a line exactly at the limit, its newline included" do
        line = %({"type":"output","text":""}\n)
        Protocol.read(IO::Memory.new(line), Protocol::WorkerMessage, limit: line.bytesize).should be_a(Protocol::Output)
      end
    end

    describe "refuses" do
      it "a line one byte over the limit" do
        line = %({"type":"output","text":""}\n)
        protocol_refuses(line, Protocol::WorkerMessage, /message over #{line.bytesize - 1} bytes/, limit: line.bytesize - 1)
      end

      it "a stream that ends inside a message" do
        protocol_refuses(%({"type":"output","te), Protocol::WorkerMessage, /stream ended inside a message/)
      end

      it "a line that isn't valid UTF-8" do
        protocol_refuses("{\"type\":\"output\",\"text\":\"\xFF\"}\n", Protocol::WorkerMessage, /not valid UTF-8/)
      end

      it "anything after the message on its line" do
        {"{}", ",", "]", "}", "1"}.each do |tail|
          protocol_refuses(%({"type":"output","text":""}#{tail}\n), Protocol::WorkerMessage, /malformed message/)
        end
      end

      it "a line that isn't one well-formed message" do
        {
          %(not json\n),
          %([]\n),
          %(\n),
          %({"text":""}\n),
          %({"type":"shout","text":""}\n),
          %({"type":"Output","text":""}\n),
          %({"type":1,"text":""}\n),
          %({"type":"output"}\n),
          %({"type":"output","text":"","colour":"red"}\n),
          %({"type":"output","text":1}\n),
          %({"type":"hello","protocol":"1","adjutant":"0.6.0"}\n),
          %({"type":"hello","protocol":99999999999,"adjutant":"0.6.0"}\n),
          %({"type":"log","severity":"Warn","source":"s","message":"m"}\n),
          %({"type":"log","severity":"loud","source":"s","message":"m"}\n),
        }.each do |line|
          protocol_refuses(line, Protocol::WorkerMessage, /malformed message/)
        end
      end

      it "a message from the other side" do
        protocol_refuses(%({"type":"answer","id":1,"decision":"allow"}\n), Protocol::WorkerMessage, /malformed message/)
        protocol_refuses(%({"type":"output","text":""}\n), Protocol::SupervisorMessage, /malformed message/)
      end

      it "a decision by any name but its own" do
        protocol_refuses(%({"type":"answer","id":1,"decision":"Allow"}\n), Protocol::SupervisorMessage, /malformed message/)
        protocol_refuses(%({"type":"answer","id":1,"decision":"maybe"}\n), Protocol::SupervisorMessage, /malformed message/)
      end

      it "deep nesting, without overflowing the stack" do
        line = %({"type":"output","text":#{"[" * 600}#{"]" * 600}}\n)
        protocol_refuses(line, Protocol::WorkerMessage, /malformed message/)
      end
    end
  end
end
