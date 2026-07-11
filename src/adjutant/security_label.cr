require "json"

module Adjutant
  # How sensitive a piece of provenance is judged to be. Ordered worst-to-
  # best as High > Elevated > None — see Sensitivity#worse_or_equal? for
  # the join rule this ordering exists to support.
  enum Sensitivity
    None
    Elevated
    High

    # True if `self` is at least as sensitive as `other` — used to pick
    # the winner when joining two tags that share a (kind, origin).
    def worse_or_equal?(other : Sensitivity) : Bool
      value >= other.value
    end
  end

  # The category of provenance a ProvenanceTag records. A closed set
  # (rather than a bare Symbol) so typos are caught at compile time and
  # the set of recognized kinds is visible in one place; also gives a
  # natural, stable JSON representation (the enum member name) for
  # FlowLog/audit output. Extend as new native modules need to label
  # values from sources not yet covered.
  enum ProvenanceKind
    File
    Network
    Env
    UserInput
  end

  # A single piece of provenance carried by a SecurityLabel: what kind of
  # source it came from, a concrete identifier for that source, and how
  # sensitive that source is judged to be by policy.
  #
  # Identity (for Set membership / equality) is (kind, origin) — two tags
  # for the same origin are the same tag regardless of sensitivity, so a
  # label's tag set never carries duplicate entries for one origin. See
  # ProvenanceTag#merge for how two same-origin tags with different
  # sensitivity are resolved on join.
  struct ProvenanceTag
    include JSON::Serializable

    getter kind : ProvenanceKind
    getter origin : String # concrete identifier — path, host, var name
    getter sensitivity : Sensitivity

    def initialize(@kind : ProvenanceKind, @origin : String, @sensitivity : Sensitivity = Sensitivity::None)
    end

    # Two tags are equal (and hash equal) based on (kind, origin) alone —
    # sensitivity is not part of identity, so a Set(ProvenanceTag) never
    # ends up with two entries for the same origin.
    def ==(other : ProvenanceTag) : Bool
      kind == other.kind && origin == other.origin
    end

    def hash(hasher)
      hasher = kind.hash(hasher)
      hasher = origin.hash(hasher)
      hasher
    end

    # Resolve two tags that share a (kind, origin) into one, keeping the
    # worse (more sensitive) of the two. Used when joining labels whose
    # tag sets overlap on origin but might disagree on sensitivity (e.g.
    # a tag was recorded before a later policy reload changed its
    # sensitivity) — should not normally happen within one script run,
    # but the merge must still be well-defined.
    def merge(other : ProvenanceTag) : ProvenanceTag
      self.sensitivity.worse_or_equal?(other.sensitivity) ? self : other
    end

    def to_s(io : IO) : Nil
      io << kind.to_s.downcase << ':' << origin
      io << '(' << sensitivity << ')' unless sensitivity.none?
    end
  end

  # JSON::Serializable converter for Set(ProvenanceTag) — Crystal's
  # JSON::Serializable does not support Set directly, only Array, so
  # SecurityLabel#tags uses this converter to serialize as a JSON array
  # and deserialize back into a Set. Kept generic-free (fixed to
  # ProvenanceTag) since that's the only Set field needing this so far.
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

  # A security label attached to a Value for information flow control —
  # an element of the powerset lattice over ProvenanceTag, ordered by set
  # inclusion (join = union). See research/IFC_DESIGN.md for the design
  # rationale.
  class SecurityLabel
    include JSON::Serializable

    @[JSON::Field(converter: Adjutant::ProvenanceTagSetConverter)]
    getter tags : Set(ProvenanceTag)

    def initialize(@tags : Set(ProvenanceTag) = Set(ProvenanceTag).new)
    end

    # Convenience: a label carrying a single tag.
    def self.of(kind : ProvenanceKind, origin : String, sensitivity : Sensitivity = Sensitivity::None) : SecurityLabel
      new(Set{ProvenanceTag.new(kind, origin, sensitivity)})
    end

    # The worst (most sensitive) tag's sensitivity, or None if there are
    # no tags. This is what a sink check compares against a RiskProfile —
    # see research/IFC_DESIGN.md's "Sink check" section.
    def sensitivity : Sensitivity
      tags.reduce(Sensitivity::None) { |worst, tag| tag.sensitivity.worse_or_equal?(worst) ? tag.sensitivity : worst }
    end

    def to_s(io : IO) : Nil
      io << "label:{" << tags.join(", ") << "}"
    end

    def ==(other : SecurityLabel) : Bool
      tags == other.tags
    end

    # Join two labels — the least upper bound in the powerset lattice:
    # set union of tags, with same-origin tags merged to their worse
    # sensitivity (see ProvenanceTag#merge). nil is the lattice bottom
    # (no provenance) and is absorbed by whichever side is present.
    def self.join(a : SecurityLabel?, b : SecurityLabel?) : SecurityLabel?
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
