require "json"

module Adjutant
  module Protocol
    # Reads a set of enum members, each by its exact name, refusing one
    # listed twice.
    module ExactEnumSet(T)
      def self.from_json(pull : JSON::PullParser) : Set(T)
        set = Set(T).new
        pull.read_array do
          member = ExactEnum(T).from_json(pull)
          pull.raise("#{member.to_s.underscore} listed twice") unless set.add?(member)
        end
        set
      end

      def self.to_json(value : Set(T), json : JSON::Builder) : Nil
        json.array { value.each(&.to_json(json)) }
      end
    end

    # A time as RFC 3339 to the nanosecond, where `Time#to_json` drops
    # the fraction of a second, which audit records need for ordering.
    # A malformed time is a parse error like any other.
    module RFC3339Time
      def self.from_json(pull : JSON::PullParser) : Time
        text = pull.read_string
        Time::Format::RFC_3339.parse(text)
      rescue Time::Format::Error | ArgumentError
        pull.raise("not an RFC 3339 time: #{text.inspect}")
      end

      def self.to_json(value : Time, json : JSON::Builder) : Nil
        json.string { |io| Time::Format::RFC_3339.format(value, io, fraction_digits: 9) }
      end
    end

    # A description of a core value, carried in a message. Built from
    # the core value with `from`, and never turned back into one: the
    # reading side gets data to show, not a rule to apply, so nothing
    # from the other side reaches a core constructor, a regex compiler
    # or the filesystem.
    abstract struct Payload
      include JSON::Serializable
      include JSON::Serializable::Strict
    end

    # A `ProvenanceTag`: where a labelled value came from.
    struct Tag < Payload
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::ProvenanceKind))]
      getter kind : ProvenanceKind
      getter origin : String
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Sensitivity))]
      getter sensitivity : Sensitivity

      def initialize(@kind : ProvenanceKind, @origin : String, @sensitivity : Sensitivity)
      end

      def self.from(tag : ProvenanceTag) : Tag
        new(tag.kind, tag.origin, tag.sensitivity)
      end
    end

    # A `RiskFlowOrigin`, as the policy wrote it.
    struct OriginPattern < Payload
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::ProvenanceKind))]
      getter kind : ProvenanceKind
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::PatternType))]
      getter pattern_type : PatternType
      getter pattern : String

      def initialize(@kind : ProvenanceKind, @pattern_type : PatternType, @pattern : String)
      end

      def self.from(origin : RiskFlowOrigin) : OriginPattern
        new(origin.kind, origin.pattern_type, origin.pattern)
      end
    end

    # A `RiskFlowSubject`, as the policy wrote it.
    struct SubjectPattern < Payload
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::PatternType))]
      getter pattern_type : PatternType
      getter pattern : String

      def initialize(@pattern_type : PatternType, @pattern : String)
      end

      def self.from(subject : RiskFlowSubject) : SubjectPattern
        new(subject.pattern_type, subject.pattern)
      end
    end

    # A `RiskFlowRule`.
    struct Rule < Payload
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Authority))]
      getter authority : Authority
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Sensitivity))]
      getter sensitivity : Sensitivity
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::RiskFlowAction))]
      getter action : RiskFlowAction
      getter origin : OriginPattern?
      getter subject : SubjectPattern?
      getter priority : Int32?

      def initialize(@authority : Authority, @sensitivity : Sensitivity, @action : RiskFlowAction,
                     @origin : OriginPattern?, @subject : SubjectPattern?, @priority : Int32?)
      end

      def self.from(rule : RiskFlowRule) : Rule
        new(rule.authority, rule.sensitivity, rule.action,
          rule.origin.try { |origin| OriginPattern.from(origin) },
          rule.subject.try { |subject| SubjectPattern.from(subject) },
          rule.priority)
      end
    end

    # A `RiskFlowMatch`: one reason a call was escalated.
    struct Match < Payload
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::RiskFlowAction))]
      getter action : RiskFlowAction
      getter rule : Rule?
      getter tag : Tag

      def initialize(@action : RiskFlowAction, @rule : Rule?, @tag : Tag)
      end

      def self.from(match : RiskFlowMatch) : Match
        new(match.action, match.rule.try { |rule| Rule.from(rule) }, Tag.from(match.tag))
      end
    end

    # A `RiskProfile`: what a call does to the world.
    struct Risk < Payload
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnumSet(Adjutant::Effect))]
      getter effects : Set(Effect)
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Reversibility))]
      getter reversible : Reversibility
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Severity))]
      getter severity : Severity
      getter note : String?

      def initialize(@effects : Set(Effect), @reversible : Reversibility, @severity : Severity, @note : String?)
      end

      def self.from(risk : RiskProfile) : Risk
        new(risk.effects, risk.reversible, risk.severity, risk.note)
      end
    end

    # A `RiskFlowDecisionRequest`: what the host is asked to decide.
    # Build one in-process with `from`, and prompt code can serve a
    # worker's Asks and an in-process `on_risk_flow_decision` alike.
    struct DecisionRequest < Payload
      getter call_name : String
      getter risk : Risk
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnumSet(Adjutant::Authority))]
      getter authorities : Set(Authority)
      getter matches : Array(Match)
      getter filename : String
      getter line : Int32
      getter subject : String?

      def initialize(@call_name : String, @risk : Risk, @authorities : Set(Authority), @matches : Array(Match),
                     @filename : String, @line : Int32, @subject : String?)
      end

      def self.from(request : RiskFlowDecisionRequest) : DecisionRequest
        new(request.call_name, Risk.from(request.risk), request.authorities,
          request.matches.map { |match| Match.from(match) },
          request.filename, request.line, request.subject)
      end
    end

    # A `RiskSummary`: what a script could do on any run.
    struct Summary < Payload
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnumSet(Adjutant::Effect))]
      getter effects : Set(Effect)
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Reversibility))]
      getter reversible : Reversibility
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Severity))]
      getter severity : Severity
      getter? iterated : Bool

      def initialize(@effects : Set(Effect), @reversible : Reversibility, @severity : Severity, @iterated : Bool)
      end

      def self.from(summary : RiskSummary) : Summary
        new(summary.effects, summary.reversible, summary.severity, summary.iterated?)
      end
    end

    # A `RiskFinding`: one call a script could make, and where it sits.
    struct Finding < Payload
      getter description : String
      getter profile : Risk
      getter line : Int32
      getter? iterated : Bool
      getter branch_path : Array(String)

      def initialize(@description : String, @profile : Risk, @line : Int32, @iterated : Bool, @branch_path : Array(String))
      end

      def self.from(finding : RiskFinding) : Finding
        new(finding.description, Risk.from(finding.profile), finding.line, finding.iterated?, finding.branch_path)
      end
    end

    # A `Span`: a place in a source file.
    struct SourceSpan < Payload
      getter filename : String?
      getter line : Int32
      getter column : Int32?
      getter length : Int32?
      getter label : String?

      def initialize(@filename : String?, @line : Int32, @column : Int32?, @length : Int32?, @label : String?)
      end

      def self.from(span : Span) : SourceSpan
        new(span.filename, span.line, span.column, span.length, span.label)
      end
    end

    # A `Diagnostic`: its code, places and substitutions. Wording comes
    # from the catalog, so a reader shows the rendering that travels
    # with it (`Raised#rendered`) rather than look the code up.
    struct DiagnosticReport < Payload
      getter code : String
      getter primary : SourceSpan?
      getter secondary : Array(SourceSpan)
      getter data : Hash(String, String)

      def initialize(@code : String, @primary : SourceSpan?, @secondary : Array(SourceSpan), @data : Hash(String, String))
      end

      def self.from(diagnostic : Diagnostic) : DiagnosticReport
        new(diagnostic.code, diagnostic.primary.try { |span| SourceSpan.from(span) },
          diagnostic.secondary.map { |span| SourceSpan.from(span) }, diagnostic.data)
      end
    end

    # `AuditRecord#decision`.
    enum AuditDecision
      Allowed
      Denied
      Rejected
    end

    # An `AuditRecord`: one broker decision.
    struct AuditEntry < Payload
      @[JSON::Field(converter: Adjutant::Protocol::RFC3339Time)]
      getter timestamp : Time
      getter verb : String
      getter subject : String
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Authority))]
      getter authority : Authority
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Protocol::AuditDecision))]
      getter decision : AuditDecision
      getter exception_class : String?

      def initialize(@timestamp : Time, @verb : String, @subject : String, @authority : Authority,
                     @decision : AuditDecision, @exception_class : String?)
      end

      # Raises ArgumentError for a decision `AuditDecision` doesn't name.
      def self.from(record : AuditRecord) : AuditEntry
        new(record.timestamp, record.verb, record.subject, record.authority,
          AuditDecision.parse(record.decision.to_s), record.exception_class)
      end
    end

    # A `RiskFlowLabel`: the tags a value carries.
    struct Label < Payload
      getter tags : Array(Tag)

      def initialize(@tags : Array(Tag))
      end

      def self.from(label : RiskFlowLabel) : Label
        new(label.tags.map { |tag| Tag.from(tag) })
      end
    end

    # A `RiskFlowEvent`: one label join during a run.
    struct FlowEvent < Payload
      getter op : String
      getter inputs : Array(Label?)
      getter result : Label?
      getter line : Int32

      def initialize(@op : String, @inputs : Array(Label?), @result : Label?, @line : Int32)
      end

      def self.from(event : RiskFlowEvent) : FlowEvent
        new(event.op, event.inputs.map { |label| label.try { |present| Label.from(present) } },
          event.result.try { |label| Label.from(label) }, event.line)
      end
    end

    # `FatalSignal#kind`.
    enum FatalKind
      Denied
      Exhausted
      Aborted
    end

    # How an assessment or a run ended.
    abstract struct Outcome < Payload
      use_json_discriminator "type", {completed: Completed, assessment: Assessment, raised: Raised, fatal: Fatal}

      # The outcome's name on the wire.
      abstract def kind : String
    end

    # A run that finished: its result's `inspect`, cut short when
    # `truncated`.
    struct Completed < Outcome
      @[JSON::Field(key: "type")]
      getter kind : String = "completed"
      getter value : String
      getter? truncated : Bool

      def initialize(@value : String, @truncated : Bool)
      end
    end

    # An assessment that finished.
    struct Assessment < Outcome
      @[JSON::Field(key: "type")]
      getter kind : String = "assessment"
      getter summary : Summary
      getter findings : Array(Finding)

      def initialize(@summary : Summary, @findings : Array(Finding))
      end
    end

    # An error the worker rendered: a script's, or one the host caused.
    # `diagnostic` is nil for an error that carries none.
    struct Raised < Outcome
      @[JSON::Field(key: "type")]
      getter kind : String = "raised"
      getter diagnostic : DiagnosticReport?
      getter rendered : String

      def initialize(@diagnostic : DiagnosticReport?, @rendered : String)
      end
    end

    # A run a `FatalSignal` ended.
    struct Fatal < Outcome
      @[JSON::Field(key: "type")]
      getter kind : String = "fatal"
      @[JSON::Field(converter: Adjutant::Protocol::ExactEnum(Adjutant::Protocol::FatalKind))]
      getter signal : FatalKind
      getter message : String
      getter data : Hash(String, String)

      def initialize(@signal : FatalKind, @message : String, @data : Hash(String, String))
      end

      # Raises ArgumentError for a kind `FatalKind` doesn't name.
      def self.from(signal : FatalSignal) : Fatal
        new(FatalKind.parse(signal.kind.to_s), signal.message || "", signal.data)
      end
    end
  end
end
