require "json"
require "log"

module Adjutant
  # What a Worker and its Supervisor say to each other over the
  # worker's stdin and stdout (research/WORKER_DESIGN.md): one JSON
  # object per line, each naming its kind in `type`.
  #
  # ```
  # Protocol.write(io, Protocol::Output.new("hello\n"))
  # Protocol.read(io, Protocol::WorkerMessage, limit: 1 << 20) # => Protocol::Output
  # ```
  module Protocol
    # Both sides must speak the same version; the worker states its own
    # in `Hello`.
    VERSION = 1

    # A line the reading side doesn't accept: over the limit, cut off,
    # not UTF-8, not one JSON object, or not a message that side
    # expects. Either side ends the run on it.
    class Violation < Exception
    end

    # Writes `message` as one line and flushes it.
    def self.write(io : IO, message : Message) : Nil
      message.to_json(io)
      io << '\n'
      io.flush
    end

    # Reads the next message as a `T` (`WorkerMessage` or
    # `SupervisorMessage`), or nil at the end of the stream. `limit` is
    # the most bytes a line may take, its newline included.
    def self.read(io : IO, klass : T.class, limit : Int32) : T? forall T
      return unless line = io.gets('\n', limit)
      unless line.ends_with?('\n')
        raise Violation.new("message over #{limit} bytes") if line.bytesize >= limit
        raise Violation.new("stream ended inside a message")
      end
      raise Violation.new("message is not valid UTF-8") unless line.valid_encoding?
      decode(line, klass)
    end

    # Parses one object as a `T`, its `type` picking the class. The
    # parser refuses anything after the object but whitespace, and the
    # discriminator's copy of it (`JSON::Builder`) stops past 99 levels
    # of nesting, both with a `JSON::Error`.
    private def self.decode(line : String, _klass : T.class) : T forall T
      T.from_json(line)
    rescue ex : JSON::Error
      raise Violation.new("malformed message: #{ex.message}")
    end

    # Reads an enum member only by the name `Enum#to_json` writes
    # ("allow"), where `Enum.from_json` also takes "Allow" and "ALLOW"
    # (HANDOFF.md §4.19).
    module ExactEnum(T)
      def self.from_json(pull : JSON::PullParser) : T
        name = pull.read_string
        T.values.find { |member| member.to_s.underscore == name } ||
          pull.raise("unknown #{T} #{name.inspect}")
      end

      def self.to_json(value : T, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end

    # Every message: no key it doesn't declare, none missing.
    abstract class Message
      include JSON::Serializable
      include JSON::Serializable::Strict
    end

    # What a Worker sends.
    abstract class WorkerMessage < Message
      use_json_discriminator "type", {hello: Hello, output: Output, log: LogEntry}
    end

    # What a Supervisor sends.
    abstract class SupervisorMessage < Message
      use_json_discriminator "type", {assess: Assess, run: Run, answer: Answer}
    end

    # The worker's first message: the protocol it speaks, and the
    # Adjutant it was built with.
    class Hello < WorkerMessage
      @[JSON::Field(key: "type")]
      getter kind : String = "hello"
      getter protocol : Int32
      getter adjutant : String

      def initialize(@protocol : Int32 = Protocol::VERSION, @adjutant : String = Adjutant::VERSION)
      end
    end

    # A chunk of the script's standard output.
    class Output < WorkerMessage
      @[JSON::Field(key: "type")]
      getter kind : String = "output"
      getter text : String

      def initialize(@text : String)
      end
    end

    # One entry from the worker's `::Log`.
    class LogEntry < WorkerMessage
      @[JSON::Field(key: "type")]
      getter kind : String = "log"
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(::Log::Severity))]
      getter severity : ::Log::Severity
      getter source : String
      getter message : String

      def initialize(@severity : ::Log::Severity, @source : String, @message : String)
      end
    end

    # Assess `source` under `policy`, a policy document.
    class Assess < SupervisorMessage
      @[JSON::Field(key: "type")]
      getter kind : String = "assess"
      getter source : String
      getter filename : String
      getter policy : String

      def initialize(@source : String, @filename : String, @policy : String)
      end
    end

    # Run `source` under `policy`, a policy document. `files` is what
    # `require` reads.
    class Run < SupervisorMessage
      @[JSON::Field(key: "type")]
      getter kind : String = "run"
      getter source : String
      getter filename : String
      getter policy : String
      getter files : Hash(String, String)
      getter instruction_limit : UInt64
      getter call_depth_limit : Int32
      getter? risk_flow_tracking : Bool

      def initialize(@source : String, @filename : String, @policy : String, @files : Hash(String, String),
                     limits : ExecutionLimits, @risk_flow_tracking : Bool)
        @instruction_limit = limits.instruction_limit
        @call_depth_limit = limits.call_depth_limit
      end

      def limits : ExecutionLimits
        ExecutionLimits.new(instruction_limit: @instruction_limit, call_depth_limit: @call_depth_limit)
      end
    end

    # The host's decision on the pending Ask `id`.
    class Answer < SupervisorMessage
      @[JSON::Field(key: "type")]
      getter kind : String = "answer"
      getter id : Int32
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::RiskFlowDecision))]
      getter decision : RiskFlowDecision

      def initialize(@id : Int32, @decision : RiskFlowDecision)
      end
    end
  end
end
