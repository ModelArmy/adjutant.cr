require "../spec_helper"
require "file_utils"

module Adjutant
  # A Supervisor::Link over pipes, with the worker's ends exposed for a
  # spec to drive. Killing it, or the worker ending, closes the worker's
  # ends, as a process's death would, and leaves the Supervisor's alone.
  # The pipes in `hold` stay open, as if a process the worker started
  # had them.
  private class SupervisorSpecLink < Supervisor::Link
    getter input : IO
    getter output : IO
    getter error : IO
    getter worker_in : IO
    getter worker_out : IO
    getter worker_err : IO
    getter? killed = false
    @ended = false

    def initialize(@hold : Array(Supervisor::Pipe) = [] of Supervisor::Pipe)
      @worker_in, @input = IO.pipe
      @output, @worker_out = IO.pipe
      @error, @worker_err = IO.pipe
    end

    def kill : Nil
      @killed = true
      close_worker
    end

    def ended? : Bool
      @ended
    end

    def wait : Process::Status?
      nil
    end

    def close_worker : Nil
      @ended = true
      @worker_out.close unless @hold.includes?(Supervisor::Pipe::Stdout)
      @worker_err.close unless @hold.includes?(Supervisor::Pipe::Stderr)
    end
  end

  # A Supervisor talking to a real Worker running in a fiber.
  private def self.supervisor_with_worker(grace : Time::Span = Supervisor::DEFAULT_GRACE) : {Supervisor, SupervisorSpecLink}
    link = SupervisorSpecLink.new
    spawn do
      begin
        Worker.new(link.worker_in, link.worker_out) { }.serve
      rescue
        # A spec that kills the worker ends it this way.
      ensure
        link.close_worker
      end
    end
    {Supervisor.new(link, grace), link}
  end

  # A Supervisor talking to a scripted fake worker. Each step is a line
  # to write, `:read` to read one line, `:stall` to wait without end, or
  # `:chatter` to write a log entry every 100 ms for 5 seconds, killed
  # or not. `:hello` writes a correct hello. `hold` is the link's.
  private def self.supervisor_with_script(steps : Array(String | Symbol), max_output : Int64 = Supervisor::DEFAULT_MAX_OUTPUT,
                                          grace : Time::Span = Supervisor::DEFAULT_GRACE,
                                          hold : Array(Supervisor::Pipe) = [] of Supervisor::Pipe) : {Supervisor, SupervisorSpecLink}
    link = SupervisorSpecLink.new(hold)
    spawn do
      begin
        steps.each do |step|
          case step
          when :hello   then link.worker_out << Protocol::Hello.new.to_json << '\n'
          when :read    then link.worker_in.gets
          when :stall   then sleep 1.hour
          when :chatter then supervisor_chatter(link.worker_out)
          when String   then link.worker_out << step << '\n'
          end
          link.worker_out.flush
        end
      rescue IO::Error
        # Killed.
      ensure
        link.close_worker unless link.killed?
      end
    end
    {Supervisor.new(link, grace, max_output), link}
  end

  private def self.supervisor_chatter(io : IO) : Nil
    50.times do
      io << SUPERVISOR_LOG << '\n'
      io.flush
      sleep 100.milliseconds
    end
  end

  private def self.supervisor_run(supervisor : Supervisor, source : String = "1", policy : String = "risk_flow: none",
                                  ceiling : Time::Span = 10.seconds) : Supervisor::RunReport
    supervisor.run(source, policy, ceiling: ceiling, filename: "task.rb") { |event| event.as?(Supervisor::Ask).try(&.answer(:allow)) }
  end

  private def self.supervisor_violation(steps : Array(String | Symbol), policy : String = "risk_flow: none") : String
    supervisor, link = supervisor_with_script(steps)
    report = supervisor_run(supervisor, policy: policy)
    link.killed?.should be_true
    report.outcome.as(Supervisor::Violated).reason
  end

  private def self.supervisor_tmpdir(&)
    path = File.join(Dir.tempdir, "adjutant-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir(path)
    begin
      yield path
    ensure
      FileUtils.rm_rf(path)
    end
  end

  # A policy that asks before `secret` is read, with `extra` under
  # `limits`.
  private def self.supervisor_asking_policy(dir : String, secret : String, limits : String = "{}") : String
    <<-YAML
      grants:
        read: { roots: [#{dir.inspect}] }
      limits: #{limits}
      risk_flow:
        patterns:
          - { kind: file, pattern: #{secret.inspect}, priority: 10, sensitivity: high }
        rules:
          - { authority: read, sensitivity: high, action: ask }
        default: reject
      YAML
  end

  SUPERVISOR_COMPLETED = %({"type":"finished","outcome":{"type":"completed","value":"1","truncated":false}})
  SUPERVISOR_LOG       = %({"type":"log","severity":"info","source":"spec","message":"still here"})

  SUPERVISOR_ASK_REQUEST = %({"call_name":"c","risk":{"effects":[],"reversible":"yes","severity":"info"},"authorities":[],"matches":[],"filename":"f","line":1})

  describe Supervisor do
    describe "with a worker" do
      it "yields output and returns the run's outcome, logs and observations" do
        supervisor, _ = supervisor_with_worker
        events = [] of Supervisor::Event
        report = supervisor.run(%(puts "hi"\n1 + 1), "risk_flow: none", ceiling: 10.seconds) { |event| events << event }
        report.outcome.should eq Supervisor::Completed.new("2", false)
        events.map(&.as(Supervisor::Output).text).join.should eq "hi\n"
        report.observed.output_bytes.should eq 3
        report.observed.asks.should eq 0
        report.observed.exit_status.should be_nil
      end

      it "keeps the audit log the worker reports, and the outcome it explains" do
        supervisor_tmpdir do |dir|
          outside = File.join(dir, "outside.txt")
          File.write(outside, "x")
          supervisor, _ = supervisor_with_worker
          report = supervisor_run(supervisor, %(Legate.read(#{outside.inspect})))
          report.outcome.as(Supervisor::Fatal).signal.should eq Protocol::FatalKind::Denied
          report.audit.map(&.decision).should eq [Protocol::AuditDecision::Denied]
        end
      end

      it "yields an Ask and sends the host's answer" do
        supervisor_tmpdir do |dir|
          secret = File.join(dir, "secret.txt")
          File.write(secret, "shh")
          supervisor, _ = supervisor_with_worker
          report = supervisor.run(%(Legate.read(#{secret.inspect})), supervisor_asking_policy(dir, secret), ceiling: 10.seconds) do |event|
            ask = event.should be_a(Supervisor::Ask)
            ask.request.call_name.should eq "Legate.read"
            ask.answer(:allow)
          end
          report.outcome.as(Supervisor::Completed).value.should start_with %("shh")
          report.observed.asks.should eq 1
        end
      end

      it "pauses the deadline while the host decides" do
        supervisor_tmpdir do |dir|
          secret = File.join(dir, "secret.txt")
          File.write(secret, "shh")
          supervisor, _ = supervisor_with_worker(grace: 100.milliseconds)
          policy = supervisor_asking_policy(dir, secret, "{ wall_clock: 1 }")
          report = supervisor.run(%(Legate.read(#{secret.inspect})), policy, ceiling: 10.seconds) do |event|
            sleep 1.5.seconds
            event.as(Supervisor::Ask).answer(:allow)
          end
          report.outcome.should be_a(Supervisor::Completed)
        end
      end

      it "kills the worker and raises when the host doesn't answer" do
        supervisor_tmpdir do |dir|
          secret = File.join(dir, "secret.txt")
          File.write(secret, "shh")
          supervisor, link = supervisor_with_worker
          expect_raises(Supervisor::UnansweredAskError, "the host's block returned without answering ask 1") do
            supervisor.run(%(Legate.read(#{secret.inspect})), supervisor_asking_policy(dir, secret), ceiling: 10.seconds) { }
          end
          link.killed?.should be_true
        end
      end

      it "refuses a second answer to one Ask" do
        ask = Supervisor::Ask.new(Protocol::DecisionRequest.from_json(SUPERVISOR_ASK_REQUEST))
        ask.answer(:allow)
        expect_raises(ArgumentError, "already answered") { ask.answer(:reject) }
      end

      it "assesses without running" do
        supervisor, _ = supervisor_with_worker
        events = [] of Supervisor::Event
        report = supervisor.assess(%(puts "ran"\nLegate.read("a")), "risk_flow: none", ceiling: 10.seconds) { |event| events << event }
        assessed = report.outcome.should be_a(Supervisor::Assessed)
        assessed.summary.effects.should contain Effect::ReadsFiles
        events.should be_empty
      end

      it "raises for a policy that doesn't load, before starting the conversation" do
        supervisor, _ = supervisor_with_worker
        expect_raises(InvalidPolicyError) { supervisor_run(supervisor, policy: "bogus: 1") }
      end

      it "serves one request" do
        supervisor, _ = supervisor_with_worker
        supervisor_run(supervisor)
        expect_raises(ArgumentError, "a Supervisor serves one request") { supervisor_run(supervisor) }
      end
    end

    describe "with a worker that misbehaves" do
      it "reports a worker that ends without finishing as Crashed, with its stderr" do
        supervisor, link = supervisor_with_script([:hello, :read] of String | Symbol)
        spawn { link.worker_err << "Stack overflow"; link.worker_err.flush }
        sleep 10.milliseconds
        report = supervisor_run(supervisor)
        report.outcome.should eq Supervisor::Crashed.new
        report.observed.stderr.should eq "Stack overflow"
      end

      it "kills a worker past the ceiling" do
        supervisor, link = supervisor_with_script([:hello, :read, :stall] of String | Symbol)
        report = supervisor_run(supervisor, ceiling: 200.milliseconds)
        report.outcome.should eq Supervisor::TimedOut.new(Supervisor::Clock::Ceiling)
        link.killed?.should be_true
      end

      it "kills a worker past wall_clock and grace" do
        supervisor, _ = supervisor_with_script([:hello, :read, :stall] of String | Symbol, grace: 100.milliseconds)
        report = supervisor_run(supervisor, policy: "risk_flow: none\nlimits: { wall_clock: 1 }")
        report.outcome.should eq Supervisor::TimedOut.new(Supervisor::Clock::Deadline)
        report.observed.elapsed.should be < 5.seconds
      end

      it "refuses each breach of the protocol, killing the worker" do
        output = %({"type":"output","text":"x"})
        audit = %({"type":"audit","record":{"timestamp":"2026-10-10T12:00:00Z","verb":"read","subject":"/a","authority":"read","decision":"allowed"}})
        completed = %({"type":"finished","outcome":{"type":"completed","value":"1","truncated":false}})
        {
          [%({"type":"hello","protocol":2,"adjutant":"9.9.9"})]                              => /worker speaks protocol 2, not 1/,
          [output]                                                                           => /expected hello, got output/,
          [:hello, :read, "not json"]                                                        => /malformed message/,
          [:hello, :read, audit, output]                                                     => /output out of order/,
          [:hello, :read, %({"type":"assessed","outcome":{"type":"raised","rendered":"r"}})] => /assessed out of order/,
          [:hello, :read, :hello]                                                            => /hello out of order/,
          [:hello, :read, completed, output]                                                 => /output after the last message/,
          [:hello, :read, %({"type":"ask","id":2,"request":#{SUPERVISOR_ASK_REQUEST}})]      => /ask 2 where ask 1 was due/,
        }.each do |steps, reason|
          supervisor_violation(steps.map(&.as(String | Symbol))).should match reason
        end
      end

      it "refuses an Ask past max_asks" do
        ask = ->(id : Int32) { %({"type":"ask","id":#{id},"request":#{SUPERVISOR_ASK_REQUEST}}) }
        steps = [:hello, :read, ask.call(1), :read, ask.call(2), :read] of String | Symbol
        supervisor_violation(steps, policy: "risk_flow: none\nlimits: { max_asks: 1 }").should eq "ask 2 is past max_asks (1)"
      end

      it "refuses output past max_output" do
        supervisor, _ = supervisor_with_script([:hello, :read, %({"type":"output","text":"hello"})] of String | Symbol, max_output: 4)
        supervisor_run(supervisor).outcome.should eq Supervisor::Violated.new("output over 4 bytes")
      end
    end

    describe "with a worker that leaves a process holding its pipes" do
      it "stops reading stdout soon after the worker finishes, and reports it" do
        steps = [:hello, :read, SUPERVISOR_COMPLETED] of String | Symbol
        supervisor, _ = supervisor_with_script(steps, hold: [Supervisor::Pipe::Stdout])
        report = supervisor_run(supervisor, ceiling: 30.seconds)
        report.outcome.should eq Supervisor::Violated.new("stdout held open after the worker ended")
        report.observed.held_open.should eq [Supervisor::Pipe::Stdout]
        report.observed.elapsed.should be < Supervisor::PIPE_WAIT + 2.seconds
      end

      it "stops reading stderr soon after the worker finishes, and reports it" do
        steps = [:hello, :read, SUPERVISOR_COMPLETED] of String | Symbol
        supervisor, _ = supervisor_with_script(steps, hold: [Supervisor::Pipe::Stderr])
        report = supervisor_run(supervisor, ceiling: 30.seconds)
        report.outcome.should eq Supervisor::Violated.new("stderr held open after the worker ended")
        report.observed.held_open.should eq [Supervisor::Pipe::Stderr]
        report.observed.elapsed.should be < Supervisor::PIPE_WAIT + 2.seconds
      end

      it "returns from a killed worker within its ceiling and the pipe wait" do
        steps = [:hello, :read, :stall] of String | Symbol
        supervisor, link = supervisor_with_script(steps, hold: [Supervisor::Pipe::Stdout, Supervisor::Pipe::Stderr])
        report = supervisor_run(supervisor, ceiling: 200.milliseconds)
        report.outcome.should eq Supervisor::TimedOut.new(Supervisor::Clock::Ceiling)
        report.observed.held_open.should eq [Supervisor::Pipe::Stdout, Supervisor::Pipe::Stderr]
        report.observed.elapsed.should be < 200.milliseconds + Supervisor::PIPE_WAIT + 1.second
        link.killed?.should be_true
      end

      it "returns within its ceiling and the pipe wait when the process keeps writing" do
        steps = [:hello, :read, :chatter] of String | Symbol
        supervisor, _ = supervisor_with_script(steps, hold: [Supervisor::Pipe::Stdout])
        report = supervisor_run(supervisor, ceiling: 200.milliseconds)
        report.outcome.should eq Supervisor::TimedOut.new(Supervisor::Clock::Ceiling)
        report.observed.elapsed.should be < 200.milliseconds + Supervisor::PIPE_WAIT + 1.second
      end

      it "doesn't count the host's time against a worker that ended with messages still in the pipe" do
        steps = [:hello, :read, %({"type":"output","text":"x"}), SUPERVISOR_COMPLETED] of String | Symbol
        supervisor, _ = supervisor_with_script(steps)
        report = supervisor.run("1", "risk_flow: none", ceiling: 30.seconds) { sleep Supervisor::PIPE_WAIT * 2 }
        report.outcome.should eq Supervisor::Completed.new("1", false)
        report.observed.held_open.should be_empty
      end
    end
  end
end
