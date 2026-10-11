require "log"
require "./protocol"

module Adjutant
  # Serves one request from a Supervisor: reads an `Assess` or a `Run`
  # from `input`, answers on `output`, and returns
  # (research/WORKER_DESIGN.md). Each request gets its own
  # Interpreter; the block given to `new` configures it, registering
  # the host's natives and modules, before any script code runs.
  #
  # A host starts a worker by running its own executable with
  # `ARGUMENT`, and begins its `main` with:
  #
  # ```
  # Adjutant::Worker.main(ARGV) { |interp| register_natives(interp) }
  # ```
  class Worker
    # The argument that makes `main` serve a request.
    ARGUMENT = "__adjutant-worker"

    # The most bytes of a run's result `inspect` sent; the rest is cut.
    RESULT_LIMIT = 128 * 1024

    # The most bytes of a rendered error sent; the rest is cut.
    RENDERED_LIMIT = 64 * 1024

    # The most bytes of standard output one `Output` carries.
    OUTPUT_CHUNK = 64 * 1024

    # Appended to a rendered error that was cut.
    CUT_MARKER = "\n[truncated]"

    # The worker can no longer speak to its Supervisor: a write
    # failed, or a reply broke the protocol. A FatalSignal, so it
    # unwinds the run past every script `rescue`, cleaning up as it
    # goes; `serve` then raises `failure`.
    class Broken < FatalSignal
      getter failure : Exception

      def initialize(@failure : Exception)
        super(:aborted, "the worker lost its supervisor: #{@failure.message}")
      end
    end

    # Serves one request on STDIN and STDOUT and exits when `argv`
    # starts with `ARGUMENT`; otherwise returns at once.
    def self.main(argv : Array(String), &configure : Interpreter -> Nil) : Nil
      return unless argv.first? == ARGUMENT
      new(STDIN, STDOUT, &configure).serve
      exit 0
    end

    # `main` for a host with nothing to register.
    def self.main(argv : Array(String)) : Nil
      main(argv) { }
    end

    # `text` with invalid UTF-8 replaced, cut to at most `limit` bytes
    # on a character boundary, and whether it was cut.
    def self.truncate(text : String, limit : Int32) : {String, Bool}
      text = text.scrub
      return {text, false} if text.bytesize <= limit
      {text.byte_slice(0, boundary(text, limit)), true}
    end

    # Yields `text`, with invalid UTF-8 replaced, in pieces of at most
    # `size` bytes, each ending on a character boundary. `size` must
    # hold the longest character, 4 bytes.
    def self.each_chunk(text : String, size : Int32, & : String ->) : Nil
      raise ArgumentError.new("chunk size #{size} is under 4 bytes") if size < 4
      text = text.scrub
      start = 0
      while start < text.bytesize
        stop = start + size >= text.bytesize ? text.bytesize : boundary(text, start + size)
        yield text.byte_slice(start, stop - start)
        start = stop
      end
    end

    # The largest byte index at most `index` that starts a character.
    private def self.boundary(text : String, index : Int32) : Int32
      bytes = text.to_slice
      while index > 0 && bytes[index] & 0xC0 == 0x80
        index -= 1
      end
      index
    end

    def initialize(@input : IO, @output : IO, &@configure : Interpreter -> Nil)
      @asks = 0
    end

    # Steps:
    # 1. Say hello, then read one request.
    # 2. Serve it. A stream that ends first is a Supervisor that went
    #    away, and needs no answer; any other message is a violation.
    # Raises what made the worker unable to answer: a Protocol::Violation,
    # an IO::Error, or a fault in Adjutant.
    def serve : Nil
      send(Protocol::Hello.new)
      case request = receive
      when Protocol::Assess then assess(request)
      when Protocol::Run    then run(request)
      when Nil              then nil
      else                       raise Protocol::Violation.new("expected a request, got #{request.kind}")
      end
    end

    private def assess(request : Protocol::Assess) : Nil
      interp = build(request.policy, {} of String => String, ExecutionLimits.new, false)
      return send(Protocol::Assessed.new(interp)) if interp.is_a?(Protocol::Raised)
      outcome =
        begin
          tree = RiskWalker.new(interp).walk_body(interp.parse(request.source, request.filename))
          findings = RiskAggregator.all_findings(tree).map { |finding| Protocol::Finding.from(finding) }
          Protocol::Assessment.new(Protocol::Summary.from(RiskAggregator.summarize(tree)), findings)
        rescue ex : ParseError | CompileError | RuntimeError | HostArgumentError | HostStateError | InternalError | AmbiguousRiskFlowPolicyError
          raised(interp, ex, request.filename)
        end
      send(Protocol::Assessed.new(outcome))
    end

    # Steps:
    # 1. Build the Interpreter; a policy that doesn't load ends the run.
    # 2. Run the script, turning how it ended into an outcome.
    # 3. Send the audit log and the risk-flow log, then the outcome.
    private def run(request : Protocol::Run) : Nil
      interp = build(request.policy, request.files, request.limits, request.risk_flow_tracking?)
      return send(Protocol::Finished.new(interp)) if interp.is_a?(Protocol::Raised)
      outcome =
        begin
          value, truncated = Worker.truncate(interp.eval(request.source, request.filename).inspect, RESULT_LIMIT)
          Protocol::Completed.new(value, truncated)
        rescue ex : Broken
          raise ex.failure
        rescue ex : FatalSignal
          Protocol::Fatal.from(ex)
        rescue ex : ParseError | CompileError | RuntimeError | HostArgumentError | HostStateError | InternalError | AmbiguousRiskFlowPolicyError
          raised(interp, ex, request.filename)
        end
      interp.effect_broker.audit_log.records.each do |record|
        send(Protocol::Audit.new(Protocol::AuditEntry.from(record)))
      end
      interp.risk_flow_log.events.each do |event|
        send(Protocol::RiskFlow.new(Protocol::FlowEvent.from(event)))
      end
      send(Protocol::Finished.new(outcome))
    end

    # An Interpreter for one request, configured by the host's block,
    # or the `Raised` a policy that doesn't load ends the request with.
    private def build(policy : String, files : Hash(String, String), limits : ExecutionLimits,
                      risk_flow_tracking : Bool) : Interpreter | Protocol::Raised
      interp = Interpreter.new(
        policy: Policy.from_yaml(policy),
        on_risk_flow_decision: ->ask(RiskFlowDecisionRequest),
        effect: PipeEffects.new(files) { |text| write_output(text) },
        limits: limits,
        risk_flow_tracking: risk_flow_tracking,
        log: forwarding_log,
      )
      @configure.call(interp)
      interp
    rescue ex : InvalidPolicyError
      Protocol::Raised.new(nil, Worker.truncate(ex.message || ex.class.name, RENDERED_LIMIT)[0])
    end

    # The `Raised` for an error `Interpreter#render_error` accepts.
    # Each type gets its own branch: a union of exception types is
    # typed as plain `Exception`, which `render_error` won't take.
    private def raised(interp : Interpreter, ex : Exception, filename : String) : Protocol::Raised
      case ex
      when ParseError                   then raised_from(interp, ex, filename)
      when CompileError                 then raised_from(interp, ex, filename)
      when RuntimeError                 then raised_from(interp, ex, filename)
      when HostArgumentError            then raised_from(interp, ex, filename)
      when HostStateError               then raised_from(interp, ex, filename)
      when InternalError                then raised_from(interp, ex, filename)
      when AmbiguousRiskFlowPolicyError then raised_from(interp, ex, filename)
      else                                   raise ex
      end
    end

    private def raised_from(interp : Interpreter, ex : T, filename : String) : Protocol::Raised forall T
      text = interp.render_error(ex, DiagnosticRenderer::Format::PlainText, filename) || ex.message || ex.class.name
      text, cut = Worker.truncate(text, RENDERED_LIMIT - CUT_MARKER.bytesize)
      Protocol::Raised.new(ex.diagnostic.try { |diagnostic| Protocol::DiagnosticReport.from(diagnostic) },
        cut ? text + CUT_MARKER : text)
    end

    # The Interpreter's `on_risk_flow_decision`: asks the Supervisor
    # and waits for its answer.
    private def ask(request : RiskFlowDecisionRequest) : RiskFlowDecision
      guard do
        @asks += 1
        send(Protocol::Ask.new(@asks, Protocol::DecisionRequest.from(request)))
        answer = receive
        unless answer.is_a?(Protocol::Answer) && answer.id == @asks
          got = answer.is_a?(Protocol::Answer) ? "the answer to ask #{answer.id}" : answer.try(&.kind) || "the end of the stream"
          raise Protocol::Violation.new("expected the answer to ask #{@asks}, got #{got}")
        end
        answer.decision
      end
    end

    private def write_output(text : String) : Nil
      guard do
        Worker.each_chunk(text, OUTPUT_CHUNK) { |chunk| send(Protocol::Output.new(chunk)) }
      end
    end

    # A Log whose entries become `LogEntry` messages.
    private def forwarding_log : ::Log
      backend = LogForwarder.new do |entry|
        message = entry.message
        entry.exception.try { |ex| message = "#{message}: #{ex.message}" }
        guard { send(Protocol::LogEntry.new(entry.severity, entry.source, message)) }
      end
      builder = ::Log::Builder.new
      builder.bind("*", :info, backend)
      builder.for(Legate::Broker::DEFAULT_LOG.source)
    end

    # Runs the block, turning any failure into `Broken`, which no
    # script can rescue.
    private def guard(& : -> T) : T forall T
      yield
    rescue ex : Exception
      raise Broken.new(ex)
    end

    private def send(message : Protocol::WorkerMessage) : Nil
      Protocol.write(@output, message, Protocol::WORKER_LINE_LIMIT)
    end

    private def receive : Protocol::SupervisorMessage?
      Protocol.read(@input, Protocol::SupervisorMessage, limit: Protocol::SUPERVISOR_LINE_LIMIT)
    end

    # Standard output goes to the Supervisor; `require` reads the
    # request's files.
    private class PipeEffects < EffectHandler
      def initialize(@files : Hash(String, String), &@write : String -> Nil)
      end

      def write_stdout(s : String) : Nil
        @write.call(s)
      end

      def vfs_read(path : String) : String?
        @files[path]?
      end

      def vfs_exists?(path : String) : Bool
        @files.has_key?(path)
      end
    end

    # Hands each entry to a block, synchronously, so entries keep
    # their place among the worker's other messages.
    private class LogForwarder < ::Log::Backend
      def initialize(&@forward : ::Log::Entry -> Nil)
        super(:sync)
      end

      def write(entry : ::Log::Entry) : Nil
        @forward.call(entry)
      end
    end
  end
end
