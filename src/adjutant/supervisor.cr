require "./protocol"
require "./worker"

module Adjutant
  # Drives one worker through one request, in the host's process
  # (research/WORKER_DESIGN.md). Owns the pipes, the framing, the
  # clocks and the caps; yields what the host must see or decide, and
  # returns how the request ended. Everything the worker says is
  # parsed strictly and bounded, and any breach ends the request.
  #
  # ```
  # supervisor = Adjutant::Supervisor.spawn
  # report = supervisor.run(source, policy_yaml, filename: "task.rb", ceiling: 15.minutes) do |event|
  #   case event
  #   in Adjutant::Supervisor::Output then ui.append(event.text)
  #   in Adjutant::Supervisor::Log    then log.info { event.message }
  #   in Adjutant::Supervisor::Ask    then event.answer(ui.approve?(event.request))
  #   end
  # end
  # ```
  class Supervisor
    # How much of the worker's stderr is kept: the end, where a crash
    # report is.
    STDERR_TAIL = 64 * 1024

    # Added to the policy's `wall_clock` for the deadline, for starting
    # the worker and sending the logs after the run.
    DEFAULT_GRACE = 5.seconds

    # The most standard output accepted from one run.
    DEFAULT_MAX_OUTPUT = 64_i64 * 1024 * 1024

    # How often the clocks are checked.
    WATCH_INTERVAL = 50.milliseconds

    # How long a pipe may keep its reader waiting once the worker has
    # ended, before the Supervisor decides another process holds it.
    PIPE_WAIT = 1.second

    # One of the worker's output pipes.
    enum Pipe
      Stdout
      Stderr
    end

    # A chunk of the script's standard output, in order.
    struct Output
      getter text : String

      def initialize(@text : String)
      end
    end

    # An entry from the worker's log.
    struct Log
      getter severity : ::Log::Severity
      getter source : String
      getter message : String

      def initialize(@severity : ::Log::Severity, @source : String, @message : String)
      end
    end

    # A risk-flow decision for the host. Call `answer` exactly once
    # before the block returns.
    class Ask
      getter request : Protocol::DecisionRequest
      getter decision : RiskFlowDecision?

      def initialize(@request : Protocol::DecisionRequest)
      end

      # Raises ArgumentError if already answered.
      def answer(decision : RiskFlowDecision) : Nil
        raise ArgumentError.new("this Ask is already answered") if @decision
        @decision = decision
      end
    end

    # What a request yields to the host's block.
    alias Event = Output | Log | Ask

    # Raised when the host's block returns without answering an Ask.
    # The worker is killed first.
    class UnansweredAskError < Exception
    end

    # A run that finished, with its result's `inspect`.
    struct Completed
      getter value : String
      getter? truncated : Bool

      def initialize(@value : String, @truncated : Bool)
      end
    end

    # An assessment that finished.
    struct Assessed
      getter summary : Protocol::Summary
      getter findings : Array(Protocol::Finding)

      def initialize(@summary : Protocol::Summary, @findings : Array(Protocol::Finding))
      end
    end

    # An error the worker rendered.
    struct Raised
      getter diagnostic : Protocol::DiagnosticReport?
      getter rendered : String

      def initialize(@diagnostic : Protocol::DiagnosticReport?, @rendered : String)
      end
    end

    # A run a FatalSignal ended.
    struct Fatal
      getter signal : Protocol::FatalKind
      getter message : String
      getter data : Hash(String, String)

      def initialize(@signal : Protocol::FatalKind, @message : String, @data : Hash(String, String))
      end
    end

    # The worker ended without finishing the request. `Observed` holds
    # its exit status and the end of its stderr.
    struct Crashed
    end

    # Which clock ended a request.
    enum Clock
      # `wall_clock` plus grace, paused while the host decides an Ask.
      Deadline
      # The host's `ceiling`, which never pauses.
      Ceiling
    end

    # A clock expired, and the worker was killed.
    struct TimedOut
      getter clock : Clock

      def initialize(@clock : Clock)
      end
    end

    # The worker broke the protocol, and was killed.
    struct Violated
      getter reason : String

      def initialize(@reason : String)
      end
    end

    # How a run can end.
    alias RunOutcome = Completed | Raised | Fatal | Crashed | TimedOut | Violated

    # How an assessment can end.
    alias AssessOutcome = Assessed | Raised | Crashed | TimedOut | Violated

    # What the Supervisor saw for itself: fact, where everything the
    # worker said is testimony.
    struct Observed
      # Nil when the worker isn't a process (a fiber in specs), or when
      # a pipe was held open: collecting the status closes the pipes,
      # which a fiber is still reading.
      getter exit_status : Process::Status?
      getter elapsed : Time::Span
      getter asks : Int32
      getter output_bytes : Int64
      getter stderr : String
      # The pipes still open `PIPE_WAIT` after the worker ended, which
      # the Supervisor stopped reading. Only a process the worker
      # started can hold them, so the worker was taken over, and that
      # process may still be running.
      getter held_open : Array(Pipe)

      def initialize(@exit_status : Process::Status?, @elapsed : Time::Span, @asks : Int32,
                     @output_bytes : Int64, @stderr : String, @held_open : Array(Pipe) = [] of Pipe)
      end
    end

    # How a run ended, the logs the worker reported, and what the
    # Supervisor observed.
    struct RunReport
      getter outcome : RunOutcome
      getter audit : Array(Protocol::AuditEntry)
      getter risk_flow : Array(Protocol::FlowEvent)
      getter observed : Observed

      def initialize(@outcome : RunOutcome, @audit : Array(Protocol::AuditEntry),
                     @risk_flow : Array(Protocol::FlowEvent), @observed : Observed)
      end
    end

    # How an assessment ended, and what the Supervisor observed.
    struct AssessReport
      getter outcome : AssessOutcome
      getter observed : Observed

      def initialize(@outcome : AssessOutcome, @observed : Observed)
      end
    end

    # The worker's ends of the conversation: its stdin, stdout and
    # stderr, and a way to stop it. `ProcessLink` wraps a process;
    # another transport, or a worker in a fiber, can stand in.
    abstract class Link
      # Where the Supervisor writes: the worker's stdin.
      abstract def input : IO
      # Where the Supervisor reads: the worker's stdout.
      abstract def output : IO
      # The worker's stderr.
      abstract def error : IO

      # Stops the worker at once. The Supervisor's reads then end as the
      # worker's ends of the pipes close. Must not close `output` or
      # `error` itself: a fiber may be reading them, and on Windows
      # closing a pipe mid-read can bring the whole process down.
      abstract def kill : Nil

      # Whether the worker has ended, without waiting and without
      # touching the pipes. False while that is unknown.
      abstract def ended? : Bool

      # Waits for the worker to end; its exit status, if it has one. May
      # close the pipes, so the Supervisor calls it only once nothing
      # is reading them.
      abstract def wait : Process::Status?
    end

    # A `Link` to a worker process.
    class ProcessLink < Link
      def initialize(@process : Process)
      end

      def input : IO
        @process.input
      end

      def output : IO
        @process.output
      end

      def error : IO
        @process.error
      end

      def kill : Nil
        @process.terminate(graceful: false)
      rescue
        # Already gone.
      end

      def ended? : Bool
        @process.terminated?
      rescue
        false
      end

      def wait : Process::Status?
        @process.wait
      end
    end

    # A Supervisor for a worker started from the current executable.
    # Raises if the executable's path can't be found.
    def self.spawn(grace : Time::Span = DEFAULT_GRACE, max_output : Int64 = DEFAULT_MAX_OUTPUT) : Supervisor
      path = Process.executable_path || raise "can't find this executable to start a worker"
      process = Process.new(path, [Worker::ARGUMENT], input: :pipe, output: :pipe, error: :pipe)
      new(process, grace, max_output)
    end

    # A Supervisor for a worker process the host started. Raises
    # ArgumentError unless its stdin, stdout and stderr are all pipes.
    def self.new(process : Process, grace : Time::Span = DEFAULT_GRACE, max_output : Int64 = DEFAULT_MAX_OUTPUT) : Supervisor
      unless process.input? && process.output? && process.error?
        raise ArgumentError.new("a worker's stdin, stdout and stderr must all be pipes")
      end
      new(ProcessLink.new(process), grace, max_output)
    end

    # What the stdout reader hands over: a message, what reading one
    # raised, or nil at the end of the stream.
    private alias Received = Protocol::WorkerMessage | Exception?

    @used = false
    @finished = false
    @done = false
    @logs_started = false
    @asks = 0
    @output_bytes = 0_i64
    @paused = Time::Span.zero
    @paused_at : Time::Instant? = nil
    @expired : Clock? = nil
    @violation : String? = nil
    @ended_at : Time::Instant? = nil
    @stdout_reading_since : Time::Instant? = nil
    @stderr_reading_since : Time::Instant? = nil
    @messages = Channel(Received).new
    @abandon = Channel(Nil).new
    @abandoned = false
    @held_open = [] of Pipe
    @stderr = IO::Memory.new
    @audit = [] of Protocol::AuditEntry
    @risk_flow = [] of Protocol::FlowEvent

    def initialize(@link : Link, @grace : Time::Span = DEFAULT_GRACE, @max_output : Int64 = DEFAULT_MAX_OUTPUT)
    end

    # Runs `source` under `policy`, a policy document, yielding each
    # `Event`. `files` is what `require` reads. `ceiling` bounds the
    # whole run, decisions included. Raises InvalidPolicyError for a
    # policy that doesn't load, before starting anything, and
    # UnansweredAskError as described there.
    def run(source : String, policy : String, *, ceiling : Time::Span, filename : String = "<eval>",
            files : Hash(String, String) = {} of String => String, limits : ExecutionLimits = ExecutionLimits.new,
            risk_flow_tracking : Bool = false, & : Event ->) : RunReport
      budgets = Policy.from_yaml(policy).grants.limits
      deadline = budgets.wall_clock.try { |seconds| seconds.seconds + @grace }
      request = Protocol::Run.new(source, filename, policy, files, limits, risk_flow_tracking)
      last, observed = converse(request, ceiling, deadline, budgets.max_asks) { |event| yield event }
      RunReport.new(run_outcome(last), @audit, @risk_flow, observed)
    end

    # Assesses `source` under `policy` without running it, yielding
    # `Log` events. Raises InvalidPolicyError as `run` does.
    def assess(source : String, policy : String, *, ceiling : Time::Span, filename : String = "<eval>",
               & : Event ->) : AssessReport
      Policy.from_yaml(policy)
      request = Protocol::Assess.new(source, filename, policy)
      last, observed = converse(request, ceiling, nil, nil) { |event| yield event }
      AssessReport.new(assess_outcome(last), observed)
    end

    private def run_outcome(last : Protocol::WorkerMessage?) : RunOutcome
      problem = ended_early
      return problem if problem
      case outcome = last.as(Protocol::Finished).outcome
      when Protocol::Completed then Completed.new(outcome.value, outcome.truncated?)
      when Protocol::Raised    then Raised.new(outcome.diagnostic, outcome.rendered)
      when Protocol::Fatal     then Fatal.new(outcome.signal, outcome.message, outcome.data)
      else                          raise "BUG: a run ended in #{outcome.kind}"
      end
    end

    private def assess_outcome(last : Protocol::WorkerMessage?) : AssessOutcome
      problem = ended_early
      return problem if problem
      case outcome = last.as(Protocol::Assessed).outcome
      when Protocol::Assessment then Assessed.new(outcome.summary, outcome.findings)
      when Protocol::Raised     then Raised.new(outcome.diagnostic, outcome.rendered)
      else                           raise "BUG: an assessment ended in #{outcome.kind}"
      end
    end

    # Why a request ended without its last message, or nil if it
    # didn't. A clock outranks a violation, since killing the worker
    # can cut its stream short mid-line; a clock that expires after the
    # last message changes nothing.
    private def ended_early : (TimedOut | Violated | Crashed)?
      if (clock = @expired) && !@finished
        TimedOut.new(clock)
      elsif reason = @violation
        Violated.new(reason)
      elsif !@finished
        Crashed.new
      end
    end

    # Steps:
    # 1. Start the clocks, and read stdout and stderr, each in its own
    #    fiber.
    # 2. Read `hello`, check its protocol, send `request`.
    # 3. Read until the request's last message, enforcing the order,
    #    yielding events and keeping the logs.
    # 4. Refuse anything after the last message, kill the worker unless
    #    it finished, and wait for both pipes to close, or for the
    #    watch to abandon them (`check_pipes`). The clocks run until
    #    then.
    # 5. Collect the exit status, unless a pipe was held open.
    # 6. Re-raise anything the host's block raised.
    # Returns the last message, if it came, and what was observed.
    #
    # Rescue bodies only record what happened; the cleanup, which waits
    # on other fibers, runs after them. On Windows an exception still
    # being handled lives in per-thread state, and another fiber
    # raising while this one waits inside a `rescue` or `ensure`
    # corrupts it, which kills the process.
    private def converse(request : Protocol::SupervisorMessage, ceiling : Time::Span, deadline : Time::Span?,
                         max_asks : Int32?, & : Event ->) : {Protocol::WorkerMessage?, Observed}
      raise ArgumentError.new("a Supervisor serves one request") if @used
      @used = true
      started = Time.instant
      stderr_done = drain_stderr
      stdout_done = read_stdout
      watch(started, ceiling, deadline)
      last = nil
      failure = nil
      begin
        last = exchange(request, max_asks) { |event| yield event }
        @finished = !last.nil?
        refuse_more if last
      rescue ex : Protocol::Violation
        @violation ||= ex.message || "protocol violation"
      rescue IO::Error
        # The worker went away; `ended_early` decides how.
      rescue ex
        failure = ex
      end
      stop_worker unless @finished && @violation.nil?
      close_input
      @messages.close
      settle(stdout_done, stderr_done)
      status = @link.wait if @held_open.empty?
      @done = true
      raise failure if failure
      {last, Observed.new(status, Time.instant - started, @asks, @output_bytes, stderr_tail, @held_open.dup)}
    end

    private def exchange(request : Protocol::SupervisorMessage, max_asks : Int32?, & : Event ->) : Protocol::WorkerMessage?
      return unless handshake(request)
      run = request.is_a?(Protocol::Run)
      while message = receive
        out_of_order(message) unless in_order?(message, run)
        case message
        when Protocol::LogEntry then yield Log.new(message.severity, message.source, message.message)
        when Protocol::Output
          count_output(message.text)
          yield Output.new(message.text)
        when Protocol::Ask then decide(message, max_asks) { |event| yield event }
        when Protocol::Audit
          @logs_started = true
          @audit << message.record
        when Protocol::RiskFlow
          @logs_started = true
          @risk_flow << message.event
        when Protocol::Finished, Protocol::Assessed then return message
        end
      end
    end

    # Reads `hello`, checks its protocol, and sends `request`. False if
    # the worker ended first.
    private def handshake(request : Protocol::SupervisorMessage) : Bool
      return false unless hello = receive
      raise Protocol::Violation.new("expected hello, got #{hello.kind}") unless hello.is_a?(Protocol::Hello)
      unless hello.protocol == Protocol::VERSION
        raise Protocol::Violation.new("worker speaks protocol #{hello.protocol}, not #{Protocol::VERSION}")
      end
      Protocol.write(@link.input, request)
      true
    end

    # Whether `message` may come now. Output and Asks belong to a run
    # before its logs; the logs and `finished` to a run; `assessed` to
    # an assessment; log entries anywhere.
    private def in_order?(message : Protocol::WorkerMessage, run : Bool) : Bool
      case message
      when Protocol::LogEntry                                      then true
      when Protocol::Output, Protocol::Ask                         then run && !@logs_started
      when Protocol::Audit, Protocol::RiskFlow, Protocol::Finished then run
      when Protocol::Assessed                                      then !run
      else                                                              false
      end
    end

    private def count_output(text : String) : Nil
      @output_bytes += text.bytesize
      raise Protocol::Violation.new("output over #{@max_output} bytes") if @output_bytes > @max_output
    end

    # Steps:
    # 1. Count the Ask; one past `max_asks` means the worker ignored
    #    its own budget.
    # 2. Pause the deadline, and let the host decide.
    # 3. Raise if the host didn't answer, and `converse` kills the
    #    worker; otherwise send the answer.
    private def decide(message : Protocol::Ask, max_asks : Int32?, & : Event ->) : Nil
      @asks += 1
      if (limit = max_asks) && @asks > limit
        raise Protocol::Violation.new("ask #{@asks} is past max_asks (#{limit})")
      end
      unless message.id == @asks
        raise Protocol::Violation.new("ask #{message.id} where ask #{@asks} was due")
      end
      ask = Ask.new(message.request)
      @paused_at = Time.instant
      begin
        yield ask
      ensure
        @paused_at.try { |since| @paused += Time.instant - since }
        @paused_at = nil
      end
      decision = ask.decision
      raise UnansweredAskError.new("the host's block returned without answering ask #{@asks}") unless decision
      Protocol.write(@link.input, Protocol::Answer.new(@asks, decision))
    end

    # After the last message, the worker may only close its stdout.
    private def refuse_more : Nil
      return unless extra = receive
      raise Protocol::Violation.new("#{extra.kind} after the last message")
    end

    private def out_of_order(message : Protocol::WorkerMessage) : NoReturn
      raise Protocol::Violation.new("#{message.kind} out of order")
    end

    # The next message from stdout, or nil at its end or once the pipes
    # are abandoned. Raises what reading the message raised.
    private def receive : Protocol::WorkerMessage?
      return if @abandoned
      received = nil
      select
      when message = @messages.receive
        received = message
      when @abandon.receive?
      end
      raise received if received.is_a?(Exception)
      received.as?(Protocol::WorkerMessage)
    end

    # Reads stdout in its own fiber, handing each message, failure or
    # end over to `receive`, so the conversation never waits on the
    # pipe itself. Stops after the end, a failure, or once `@messages`
    # closes. The channel receives when it has stopped reading.
    private def read_stdout : Channel(Nil)
      done = Channel(Nil).new(1)
      spawn do
        loop do
          received = read_message
          break unless hand_over(received) && received.is_a?(Protocol::WorkerMessage)
        end
        done.send(nil)
      end
      done
    end

    private def read_message : Received
      @stdout_reading_since = Time.instant
      Protocol.read(@link.output, Protocol::WorkerMessage, limit: Protocol::WORKER_LINE_LIMIT)
    rescue ex
      ex
    ensure
      @stdout_reading_since = nil
    end

    # False once the conversation has stopped receiving.
    private def hand_over(received : Received) : Bool
      @messages.send(received)
      true
    rescue Channel::ClosedError
      false
    end

    # Waits until both readers have stopped, or the pipes are abandoned.
    private def settle(stdout_done : Channel(Nil), stderr_done : Channel(Nil)) : Nil
      stdout = stderr = false
      until (stdout && stderr) || @abandoned
        select
        when stdout_done.receive then stdout = true
        when stderr_done.receive then stderr = true
        when @abandon.receive?
        end
      end
    end

    private def close_input : Nil
      @link.input.close
    rescue IO::Error
    end

    # Until the request is over: kills the worker when a clock expires,
    # notes when the worker has ended, and abandons pipes held open
    # past that.
    private def watch(started : Time::Instant, ceiling : Time::Span, deadline : Time::Span?) : Nil
      spawn do
        until @done
          now = Time.instant
          expire(now, started, ceiling, deadline) unless @expired
          @ended_at = now if @ended_at.nil? && @link.ended?
          check_pipes(now, started, ceiling) unless @abandoned
          sleep WATCH_INTERVAL
        end
      end
    end

    # Kills the worker if a clock has expired: the ceiling always runs,
    # the deadline only while no Ask is with the host.
    private def expire(now : Time::Instant, started : Time::Instant, ceiling : Time::Span, deadline : Time::Span?) : Nil
      clock =
        if now - started >= ceiling
          Clock::Ceiling
        elsif (limit = deadline) && running(started, now) >= limit
          Clock::Deadline
        end
      return unless clock
      @expired = clock
      stop_worker
    end

    # Abandons the pipes once one has kept its reader waiting
    # `PIPE_WAIT` since the worker ended, or once the ceiling is
    # `PIPE_WAIT` past, which bounds a process that keeps writing.
    # Every pipe still being read then is held open: the worker's ends
    # closed when it ended, so another process has them. Time a reader
    # spends waiting on the host doesn't count, since it isn't reading.
    private def check_pipes(now : Time::Instant, started : Time::Instant, ceiling : Time::Span) : Nil
      reading = {Pipe::Stdout => @stdout_reading_since, Pipe::Stderr => @stderr_reading_since}.compact
      return unless now - started >= ceiling + PIPE_WAIT || held?(now, reading.values)
      @held_open = reading.keys
      unless @held_open.empty?
        @violation ||= "#{@held_open.map(&.to_s.downcase).join(" and ")} held open after the worker ended"
      end
      @abandoned = true
      @abandon.close
    end

    private def held?(now : Time::Instant, reading_since : Array(Time::Instant)) : Bool
      return false unless ended = @ended_at
      reading_since.any? { |since| now - {since, ended}.max >= PIPE_WAIT }
    end

    private def stop_worker : Nil
      @ended_at ||= Time.instant
      @link.kill
    end

    # Time since `started`, less any spent waiting on the host.
    private def running(started : Time::Instant, now : Time::Instant) : Time::Span
      waiting = @paused + (@paused_at.try { |since| now - since } || Time::Span.zero)
      now - started - waiting
    end

    # Copies stderr into `@stderr`, keeping about the last
    # `STDERR_TAIL` bytes. The channel receives when it has stopped
    # reading.
    private def drain_stderr : Channel(Nil)
      done = Channel(Nil).new(1)
      spawn do
        buffer = Bytes.new(4096)
        while (count = read_stderr(buffer)) > 0
          @stderr.write(buffer[0, count])
          trim_stderr if @stderr.size > 2 * STDERR_TAIL
        end
        done.send(nil)
      end
      done
    end

    # 0 at the end of stderr, or when reading it fails.
    private def read_stderr(buffer : Bytes) : Int32
      @stderr_reading_since = Time.instant
      @link.error.read(buffer)
    rescue
      0
    ensure
      @stderr_reading_since = nil
    end

    private def trim_stderr : Nil
      tail = last_bytes(@stderr.to_slice, STDERR_TAIL).dup
      @stderr = IO::Memory.new
      @stderr.write(tail)
    end

    private def stderr_tail : String
      String.new(last_bytes(@stderr.to_slice, STDERR_TAIL)).scrub
    end

    private def last_bytes(bytes : Bytes, count : Int32) : Bytes
      bytes.size > count ? bytes[bytes.size - count, count] : bytes
    end
  end
end
