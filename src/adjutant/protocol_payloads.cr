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
  end
end
