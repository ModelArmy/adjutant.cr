require "../spec_helper"

module Adjutant
  # The built `worker_host` sample, which serves as a worker when started
  # with `Worker::ARGUMENT`. `ops build` builds it; ADJUTANT_WORKER_HOST
  # points elsewhere.
  WORKER_HOST = ENV["ADJUTANT_WORKER_HOST"]? ||
                File.join("bin", "debug", {% if flag?(:win32) %} "worker_host.exe" {% else %} "worker_host" {% end %})

  private def self.worker_process(args : Array(String) = [Worker::ARGUMENT],
                                  error : Process::Redirect = Process::Redirect::Pipe) : Process
    unless File.file?(WORKER_HOST)
      raise "#{WORKER_HOST} is missing: build the samples first (ops build), or set ADJUTANT_WORKER_HOST"
    end
    Process.new(WORKER_HOST, args, input: :pipe, output: :pipe, error: error)
  end

  describe "Supervisor with a worker process" do
    it "refuses a process whose stderr isn't a pipe" do
      process = worker_process(error: Process::Redirect::Close)
      begin
        expect_raises(ArgumentError, "a worker's stdin, stdout and stderr must all be pipes") { Supervisor.new(process) }
      ensure
        process.terminate(graceful: false)
        process.wait
      end
    end

    it "runs a script, and sees the worker exit cleanly" do
      events = [] of Supervisor::Event
      report = Supervisor.new(worker_process).run(%(puts "hi"\n6 * 7), "risk_flow: none", ceiling: 30.seconds) do |event|
        events << event
      end
      report.outcome.should eq Supervisor::Completed.new("42", false)
      events.map(&.as(Supervisor::Output).text).join.should eq "hi\n"
      report.observed.exit_status.try(&.success?).should be_true
    end

    it "kills a worker past the ceiling" do
      report = Supervisor.new(worker_process).run("while true\nend", "risk_flow: none", ceiling: 500.milliseconds) { }
      report.outcome.should eq Supervisor::TimedOut.new(Supervisor::Clock::Ceiling)
      report.observed.exit_status.try(&.success?).should be_false
    end

    it "reports an executable that doesn't serve as Crashed, keeping its stderr" do
      report = Supervisor.new(worker_process(args: [] of String)).run("1", "risk_flow: none", ceiling: 30.seconds) { }
      report.outcome.should eq Supervisor::Crashed.new
      report.observed.stderr.should contain "Usage: worker_host"
      report.observed.exit_status.try(&.success?).should be_false
    end
  end
end
