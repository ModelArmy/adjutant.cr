require "json"

module Adjutant
  # How sensitive a source is judged to be: High, then Elevated, then
  # None.
  enum Sensitivity
    None
    Elevated
    High

    # Whether `self` is at least as sensitive as `other`.
    def worse_or_equal?(other : Sensitivity) : Bool
      value >= other.value
    end
  end

  # The kind of source a ProvenanceTag records. Serialized by member
  # name. Extend it when a module labels data from a new kind of
  # source.
  enum ProvenanceKind
    File
    Host
    Env
    UserInput
  end

  # One piece of provenance: the kind of source, its identifier, and
  # the sensitivity policy gives it. Identity is `(kind, origin)`
  # alone, so a label never holds two tags for one origin; see
  # `merge`.
  struct ProvenanceTag
    include JSON::Serializable

    getter kind : ProvenanceKind
    getter origin : String # concrete identifier — path, host, var name
    getter sensitivity : Sensitivity

    def initialize(@kind : ProvenanceKind, @origin : String, @sensitivity : Sensitivity = Sensitivity::None)
    end

    # Equal, and hashed, by `(kind, origin)` alone.
    def ==(other : ProvenanceTag) : Bool
      kind == other.kind && origin == other.origin
    end

    def hash(hasher)
      hasher = kind.hash(hasher)
      hasher = origin.hash(hasher)
      hasher
    end

    # Combines two tags for the same origin, keeping the worse
    # sensitivity. Within one run they normally agree.
    def merge(other : ProvenanceTag) : ProvenanceTag
      sensitivity.worse_or_equal?(other.sensitivity) ? self : other
    end

    def to_s(io : IO) : Nil
      io << kind.to_s.downcase << ':' << origin
      io << '(' << sensitivity << ')' unless sensitivity.none?
    end
  end

  # Serializes Set(ProvenanceTag) as a JSON array, since
  # JSON::Serializable doesn't handle Set.
  module ProvenanceTagSetConverter
    def self.to_json(value : Set(ProvenanceTag), json : JSON::Builder) : Nil
      json.array do
        value.each(&.to_json(json))
      end
    end

    def self.from_json(pull : JSON::PullParser) : Set(ProvenanceTag)
      result = Set(ProvenanceTag).new
      pull.read_array do
        result << ProvenanceTag.new(pull)
      end
      result
    end
  end

  # A value's provenance: a set of tags, ordered by inclusion, with
  # join as union. See research/IFC_DESIGN.md.
  class RiskFlowLabel
    include JSON::Serializable

    @[JSON::Field(converter: Adjutant::ProvenanceTagSetConverter)]
    getter tags : Set(ProvenanceTag)

    def initialize(@tags : Set(ProvenanceTag) = Set(ProvenanceTag).new)
    end

    # A label with one tag.
    def self.of(kind : ProvenanceKind, origin : String, sensitivity : Sensitivity = Sensitivity::None) : RiskFlowLabel
      new(Set{ProvenanceTag.new(kind, origin, sensitivity)})
    end

    # The worst sensitivity among the tags, or None. What the
    # risk-flow check compares against the policy.
    def sensitivity : Sensitivity
      tags.reduce(Sensitivity::None) { |worst, tag| tag.sensitivity.worse_or_equal?(worst) ? tag.sensitivity : worst }
    end

    def to_s(io : IO) : Nil
      io << "label:{" << tags.join(", ") << "}"
    end

    def ==(other : RiskFlowLabel) : Bool
      tags == other.tags
    end

    # The union of both labels' tags, same-origin tags merged. Nil
    # means no provenance and is absorbed by the other side.
    def self.join(a : RiskFlowLabel?, b : RiskFlowLabel?) : RiskFlowLabel?
      return b if a.nil?
      return a if b.nil?
      return a if a.same?(b)

      merged = Hash(ProvenanceTag, ProvenanceTag).new
      a.tags.each { |tag| merged[tag] = tag }
      b.tags.each { |tag| merged[tag] = merged.has_key?(tag) ? merged[tag].merge(tag) : tag }
      new(merged.values.to_set)
    end
  end
end
