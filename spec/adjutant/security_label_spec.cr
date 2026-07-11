require "../spec_helper"

module Adjutant
  describe ProvenanceTag do
    it "is equal to another tag with the same kind and origin, regardless of sensitivity" do
      a = ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::None)
      b = ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
      a.should eq b
    end

    it "is not equal to a tag with a different origin" do
      a = ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd")
      b = ProvenanceTag.new(ProvenanceKind::File, "/etc/hosts")
      a.should_not eq b
    end

    it "is not equal to a tag with a different kind, same origin string" do
      a = ProvenanceTag.new(ProvenanceKind::File, "example.com")
      b = ProvenanceTag.new(ProvenanceKind::Network, "example.com")
      a.should_not eq b
    end

    it "merge keeps the worse sensitivity" do
      a = ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::None)
      b = ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
      a.merge(b).sensitivity.should eq Sensitivity::High
      b.merge(a).sensitivity.should eq Sensitivity::High
    end

    it "a Set(ProvenanceTag) dedupes by (kind, origin)" do
      set = Set{
        ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::None),
        ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::High),
      }
      set.size.should eq 1
    end
  end

  describe Sensitivity do
    it "orders None < Elevated < High" do
      Sensitivity::High.worse_or_equal?(Sensitivity::Elevated).should be_true
      Sensitivity::Elevated.worse_or_equal?(Sensitivity::None).should be_true
      Sensitivity::None.worse_or_equal?(Sensitivity::Elevated).should be_false
    end

    it "worse_or_equal? is true for equal sensitivities" do
      Sensitivity::Elevated.worse_or_equal?(Sensitivity::Elevated).should be_true
    end
  end

  describe SecurityLabel do
    it ".of builds a single-tag label" do
      l = SecurityLabel.of(ProvenanceKind::Network, "example.com", Sensitivity::Elevated)
      l.tags.size.should eq 1
      l.tags.first.kind.should eq ProvenanceKind::Network
      l.tags.first.origin.should eq "example.com"
      l.tags.first.sensitivity.should eq Sensitivity::Elevated
    end

    it "an empty label has None sensitivity" do
      SecurityLabel.new.sensitivity.should eq Sensitivity::None
    end

    describe ".join" do
      it "returns the other side when one side is nil" do
        l = SecurityLabel.of(ProvenanceKind::File, "/etc/hosts")
        SecurityLabel.join(nil, l).should eq l
        SecurityLabel.join(l, nil).should eq l
      end

      it "returns nil when both sides are nil" do
        SecurityLabel.join(nil, nil).should be_nil
      end

      it "unions disjoint tag sets" do
        a = SecurityLabel.of(ProvenanceKind::File, "/etc/hosts")
        b = SecurityLabel.of(ProvenanceKind::Network, "example.com")
        joined = SecurityLabel.join(a, b).not_nil!
        joined.tags.size.should eq 2
      end

      it "merges overlapping origins to the worse sensitivity instead of duplicating" do
        a = SecurityLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::None)
        b = SecurityLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
        joined = SecurityLabel.join(a, b).not_nil!
        joined.tags.size.should eq 1
        joined.sensitivity.should eq Sensitivity::High
      end

      it "join is commutative for disjoint tag sets" do
        a = SecurityLabel.of(ProvenanceKind::File, "/etc/hosts")
        b = SecurityLabel.of(ProvenanceKind::Network, "example.com")
        SecurityLabel.join(a, b).should eq SecurityLabel.join(b, a)
      end

      it "join is associative" do
        a = SecurityLabel.of(ProvenanceKind::File, "/etc/hosts")
        b = SecurityLabel.of(ProvenanceKind::Network, "example.com")
        c = SecurityLabel.of(ProvenanceKind::Env, "API_KEY", Sensitivity::High)

        left = SecurityLabel.join(SecurityLabel.join(a, b), c)
        right = SecurityLabel.join(a, SecurityLabel.join(b, c))
        left.should eq right
      end

      it "joining a label with itself is idempotent" do
        a = SecurityLabel.of(ProvenanceKind::File, "/etc/hosts", Sensitivity::Elevated)
        SecurityLabel.join(a, a).should eq a
      end
    end

    describe "#sensitivity" do
      it "reflects the single worst tag among several" do
        l = SecurityLabel.new(Set{
          ProvenanceTag.new(ProvenanceKind::File, "/etc/hosts", Sensitivity::None),
          ProvenanceTag.new(ProvenanceKind::Network, "example.com", Sensitivity::Elevated),
          ProvenanceTag.new(ProvenanceKind::Env, "API_KEY", Sensitivity::High),
        })
        l.sensitivity.should eq Sensitivity::High
      end
    end

    describe "JSON round-trip" do
      it "round-trips a single-tag label" do
        original = SecurityLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
        parsed = SecurityLabel.from_json(original.to_json)
        parsed.should eq original
        parsed.sensitivity.should eq Sensitivity::High
      end

      it "round-trips a multi-tag label" do
        original = SecurityLabel.new(Set{
          ProvenanceTag.new(ProvenanceKind::File, "/etc/hosts", Sensitivity::None),
          ProvenanceTag.new(ProvenanceKind::Network, "example.com", Sensitivity::Elevated),
        })
        parsed = SecurityLabel.from_json(original.to_json)
        parsed.tags.should eq original.tags
      end

      it "round-trips an empty label" do
        original = SecurityLabel.new
        parsed = SecurityLabel.from_json(original.to_json)
        parsed.tags.should be_empty
      end

      it "round-trips a bare ProvenanceTag" do
        original = ProvenanceTag.new(ProvenanceKind::UserInput, "stdin", Sensitivity::Elevated)
        parsed = ProvenanceTag.from_json(original.to_json)
        parsed.should eq original
        parsed.sensitivity.should eq Sensitivity::Elevated
      end
    end
  end

  describe "Interpreter flow_log wiring" do
    it "defaults to a disabled flow_log" do
      interp, _ = make_interp
      interp.flow_log.enabled?.should be_false
    end

    it "flow_tracking: true enables the flow_log" do
      ef = TestEffectHandler.new
      interp = Interpreter.new(effect: ef, flow_tracking: true)
      interp.flow_log.enabled?.should be_true
    end

    it "flow_log persists across multiple eval calls on the same interpreter" do
      ef = TestEffectHandler.new
      interp = Interpreter.new(effect: ef, flow_tracking: true)
      interp.eval("1 + 1")
      log_after_first = interp.flow_log
      interp.eval("2 + 2")
      interp.flow_log.should be log_after_first
    end
  end
end
