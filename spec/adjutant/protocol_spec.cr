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

  # The names of `T`'s instance variables, sorted.
  private def self.protocol_field_names(klass : T.class) : Array(String) forall T
    {{ T.instance_vars.map(&.name.stringify).sort }}
  end

  private def self.protocol_decision_request : RiskFlowDecisionRequest
    rule = RiskFlowRule.new(Authority::Net, Sensitivity::High, RiskFlowAction::Ask,
      origin: RiskFlowOrigin.new(ProvenanceKind::Env, "_KEY$", PatternType::Regex),
      subject: RiskFlowSubject.new("https://api.example.com:443"), priority: 10)
    tag = ProvenanceTag.new(ProvenanceKind::Env, "API_KEY", Sensitivity::High)
    risk = RiskProfile.new(Set{Effect::NetworkEgress}, Reversibility::No, Severity::Warning)
    RiskFlowDecisionRequest.new("Legate.fetch", risk, Set{Authority::Net},
      [RiskFlowMatch.new(RiskFlowAction::Ask, rule, tag), RiskFlowMatch.new(RiskFlowAction::Ask, nil, tag)],
      "task.rb", 3, "https://api.example.com:443")
  end

  # An Ask as a worker would write it, with `risk` in place.
  private def self.protocol_ask_line(risk : String) : String
    %({"type":"ask","id":1,"request":{"call_name":"c","risk":#{risk},"authorities":["net"],"matches":[],"filename":"f","line":1}}\n)
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

      it "an Ask, describing every part of the decision request" do
        view = Protocol::DecisionRequest.from(protocol_decision_request)
        ask = protocol_round_trip(Protocol::Ask.new(7, view), Protocol::WorkerMessage).should be_a(Protocol::Ask)
        ask.id.should eq 7
        ask.request.should eq view
        rule = ask.request.matches.first.rule.should be_a(Protocol::Rule)
        rule.origin.should eq Protocol::OriginPattern.new(ProvenanceKind::Env, PatternType::Regex, "_KEY$")
        rule.subject.should eq Protocol::SubjectPattern.new(PatternType::Exact, "https://api.example.com:443")
        rule.priority.should eq 10
        ask.request.matches.last.rule.should be_nil
        ask.request.risk.effects.should eq Set{Effect::NetworkEgress}
        ask.request.subject.should eq "https://api.example.com:443"
      end

      it "an Audit" do
        record = AuditRecord.new("read", "/work/a.txt", Authority::Read, :denied, "Legate::Denied",
          Time.utc(2026, 10, 10, 12, 30, 15, nanosecond: 250_000_000))
        sent = Protocol::AuditEntry.from(record)
        sent.decision.should eq Protocol::AuditDecision::Denied
        audit = protocol_round_trip(Protocol::Audit.new(sent), Protocol::WorkerMessage).should be_a(Protocol::Audit)
        audit.record.should eq sent
      end

      it "a RiskFlow" do
        secret = RiskFlowLabel.of(ProvenanceKind::File, "/work/.env", Sensitivity::High)
        sent = Protocol::FlowEvent.from(RiskFlowEvent.new("Add", [secret, nil], secret, 4))
        flow = protocol_round_trip(Protocol::RiskFlow.new(sent), Protocol::WorkerMessage).should be_a(Protocol::RiskFlow)
        flow.event.should eq sent
        flow.event.inputs.last.should be_nil
      end

      it "an Assessed carrying an Assessment" do
        summary = RiskSummary.new(Set{Effect::ReadsFiles}, Reversibility::Yes, Severity::Info, true)
        finding = RiskFinding.new("Legate.read", RiskProfile.new(Set{Effect::ReadsFiles}), 2, true, ["if branch"])
        sent = Protocol::Assessment.new(Protocol::Summary.from(summary), [Protocol::Finding.from(finding)])
        assessed = protocol_round_trip(Protocol::Assessed.new(sent), Protocol::WorkerMessage).should be_a(Protocol::Assessed)
        assessed.outcome.should eq sent
      end

      it "an Assessed carrying a Raised, with its diagnostic's places and data" do
        diagnostic = Diagnostic.new("P001", Span.new(3, 5, 2, "task.rb", "here"), [Span.new(1)], {"token" => "end"})
        sent = Protocol::Raised.new(Protocol::DiagnosticReport.from(diagnostic), "error[P001]: ...")
        assessed = protocol_round_trip(Protocol::Assessed.new(sent), Protocol::WorkerMessage).should be_a(Protocol::Assessed)
        assessed.outcome.should eq sent
      end

      it "a Finished carrying each outcome a run can end in" do
        [
          Protocol::Completed.new("[1, 2]", false),
          Protocol::Raised.new(nil, "host error"),
          Protocol::Fatal.from(FatalSignal.new(:exhausted, "wall_clock budget exceeded", {"budget" => "wall_clock"})),
        ].each do |sent|
          finished = protocol_round_trip(Protocol::Finished.new(sent), Protocol::WorkerMessage).should be_a(Protocol::Finished)
          finished.outcome.should eq sent
        end
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

    # A field added to a core type must be added to its description,
    # or excluded here as derived.
    describe "payloads" do
      it "describe every field of their core type, bar what's derived" do
        protocol_field_names(Protocol::Tag).should eq protocol_field_names(ProvenanceTag)
        protocol_field_names(Protocol::OriginPattern).should eq protocol_field_names(RiskFlowOrigin) - %w[matched regex]
        protocol_field_names(Protocol::SubjectPattern).should eq protocol_field_names(RiskFlowSubject) - %w[matched regex]
        protocol_field_names(Protocol::Rule).should eq protocol_field_names(RiskFlowRule)
        protocol_field_names(Protocol::Match).should eq protocol_field_names(RiskFlowMatch)
        protocol_field_names(Protocol::Risk).should eq protocol_field_names(RiskProfile)
        protocol_field_names(Protocol::DecisionRequest).should eq protocol_field_names(RiskFlowDecisionRequest)
        protocol_field_names(Protocol::Summary).should eq protocol_field_names(RiskSummary)
        protocol_field_names(Protocol::Finding).should eq protocol_field_names(RiskFinding)
        protocol_field_names(Protocol::SourceSpan).should eq protocol_field_names(Span)
        protocol_field_names(Protocol::DiagnosticReport).should eq protocol_field_names(Diagnostic)
        protocol_field_names(Protocol::AuditEntry).should eq protocol_field_names(AuditRecord)
        protocol_field_names(Protocol::Label).should eq protocol_field_names(RiskFlowLabel)
        protocol_field_names(Protocol::FlowEvent).should eq protocol_field_names(RiskFlowEvent)
      end

      it "refuse an outcome their message can't end in, on the writing side" do
        completed = Protocol::Completed.new("1", false)
        assessment = Protocol::Assessment.new(Protocol::Summary.from(RiskSummary.none), [] of Protocol::Finding)
        expect_raises(ArgumentError, "an assessment can't end in completed") { Protocol::Assessed.new(completed) }
        expect_raises(ArgumentError, "a run can't end in assessment") { Protocol::Finished.new(assessment) }
      end

      it "refuse a core value they have no name for, on the writing side" do
        expect_raises(ArgumentError) { Protocol::Fatal.from(FatalSignal.new(:vanished, "gone")) }
        expect_raises(ArgumentError) do
          Protocol::AuditEntry.from(AuditRecord.new("read", "/a", Authority::Read, :waved_through))
        end
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

      it "a payload with an enum member listed twice, misnamed, or an unknown key" do
        valid = %({"effects":["network_egress"],"reversible":"no","severity":"warning"})
        Protocol.read(IO::Memory.new(protocol_ask_line(valid)), Protocol::WorkerMessage, limit: 1024).should be_a(Protocol::Ask)
        {
          %({"effects":["network_egress","network_egress"],"reversible":"no","severity":"warning"}) => /network_egress listed twice/,
          %({"effects":["NetworkEgress"],"reversible":"no","severity":"warning"})                   => /unknown Adjutant::Effect/,
          %({"effects":[],"reversible":"no","severity":"warning","colour":"red"})                   => /Unknown JSON attribute: colour/,
        }.each do |risk, message|
          protocol_refuses(protocol_ask_line(risk), Protocol::WorkerMessage, message)
        end
      end

      it "an outcome its message can't end in" do
        completed = %({"type":"completed","value":"1","truncated":false})
        assessment = %({"type":"assessment","summary":{"effects":[],"reversible":"yes","severity":"info","iterated":false},"findings":[]})
        Protocol.read(IO::Memory.new(%({"type":"finished","outcome":#{completed}}\n)), Protocol::WorkerMessage, limit: 1024)
          .should be_a(Protocol::Finished)
        Protocol.read(IO::Memory.new(%({"type":"assessed","outcome":#{assessment}}\n)), Protocol::WorkerMessage, limit: 1024)
          .should be_a(Protocol::Assessed)
        protocol_refuses(%({"type":"assessed","outcome":#{completed}}\n), Protocol::WorkerMessage, /an assessment can't end in completed/)
        protocol_refuses(%({"type":"finished","outcome":#{assessment}}\n), Protocol::WorkerMessage, /a run can't end in assessment/)
        protocol_refuses(%({"type":"finished","outcome":{"type":"crashed"}}\n), Protocol::WorkerMessage, /malformed message/)
      end

      it "an audit record with a malformed time or a misnamed decision" do
        line = ->(timestamp : String, decision : String) do
          %({"type":"audit","record":{"timestamp":#{timestamp.to_json},"verb":"read","subject":"/a","authority":"read","decision":#{decision.to_json}}}\n)
        end
        Protocol.read(IO::Memory.new(line.call("2026-10-10T12:00:00Z", "allowed")), Protocol::WorkerMessage, limit: 1024)
          .should be_a(Protocol::Audit)
        protocol_refuses(line.call("yesterday", "allowed"), Protocol::WorkerMessage, /not an RFC 3339 time: "yesterday"/)
        protocol_refuses(line.call("2026-13-45T00:00:00Z", "allowed"), Protocol::WorkerMessage, /not an RFC 3339 time/)
        protocol_refuses(line.call("2026-10-10T12:00:00Z", "Allowed"), Protocol::WorkerMessage, /unknown Adjutant::Protocol::AuditDecision/)
      end

      it "a fatal signal it has no name for" do
        protocol_refuses(%({"type":"finished","outcome":{"type":"fatal","signal":"crashed","message":"m","data":{}}}\n),
          Protocol::WorkerMessage, /unknown Adjutant::Protocol::FatalKind/)
      end

      it "deep nesting, without overflowing the stack" do
        line = %({"type":"output","text":#{"[" * 600}#{"]" * 600}}\n)
        protocol_refuses(line, Protocol::WorkerMessage, /malformed message/)
      end
    end
  end
end
