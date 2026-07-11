require "../spec_helper"

module Adjutant
  describe ProvenanceTag do
    it "is equal to another tag with the same kind and origin, regardless of sensitivity" do
      a = ProvenanceTag.new(:file, "/etc/passwd", Sensitivity::None)
      b = ProvenanceTag.new(:file, "/etc/passwd", Sensitivity::High)
      a.should eq b
    end

    it "is not equal to a tag with a different origin" do
      a = ProvenanceTag.new(:file, "/etc/passwd")
      b = ProvenanceTag.new(:file, "/etc/hosts")
      a.should_not eq b
    end

    it "is not equal to a tag with a different kind, same origin string" do
      a = ProvenanceTag.new(:file, "example.com")
      b = ProvenanceTag.new(:network, "example.com")
      a.should_not eq b
    end

    it "merge keeps the worse sensitivity" do
      a = ProvenanceTag.new(:file, "/etc/passwd", Sensitivity::None)
      b = ProvenanceTag.new(:file, "/etc/passwd", Sensitivity::High)
      a.merge(b).sensitivity.should eq Sensitivity::High
      b.merge(a).sensitivity.should eq Sensitivity::High
    end

    it "a Set(ProvenanceTag) dedupes by (kind, origin)" do
      set = Set{
        ProvenanceTag.new(:file, "/etc/passwd", Sensitivity::None),
        ProvenanceTag.new(:file, "/etc/passwd", Sensitivity::High),
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
      l = SecurityLabel.of(:network, "example.com", Sensitivity::Elevated)
      l.tags.size.should eq 1
      l.tags.first.kind.should eq :network
      l.tags.first.origin.should eq "example.com"
      l.tags.first.sensitivity.should eq Sensitivity::Elevated
    end

    it "an empty label has None sensitivity" do
      SecurityLabel.new.sensitivity.should eq Sensitivity::None
    end

    describe ".join" do
      it "returns the other side when one side is nil" do
        l = SecurityLabel.of(:file, "/etc/hosts")
        SecurityLabel.join(nil, l).should eq l
        SecurityLabel.join(l, nil).should eq l
      end

      it "returns nil when both sides are nil" do
        SecurityLabel.join(nil, nil).should be_nil
      end

      it "unions disjoint tag sets" do
        a = SecurityLabel.of(:file, "/etc/hosts")
        b = SecurityLabel.of(:network, "example.com")
        joined = SecurityLabel.join(a, b).not_nil!
        joined.tags.size.should eq 2
      end

      it "merges overlapping origins to the worse sensitivity instead of duplicating" do
        a = SecurityLabel.of(:file, "/etc/passwd", Sensitivity::None)
        b = SecurityLabel.of(:file, "/etc/passwd", Sensitivity::High)
        joined = SecurityLabel.join(a, b).not_nil!
        joined.tags.size.should eq 1
        joined.sensitivity.should eq Sensitivity::High
      end

      it "join is commutative for disjoint tag sets" do
        a = SecurityLabel.of(:file, "/etc/hosts")
        b = SecurityLabel.of(:network, "example.com")
        SecurityLabel.join(a, b).should eq SecurityLabel.join(b, a)
      end

      it "join is associative" do
        a = SecurityLabel.of(:file, "/etc/hosts")
        b = SecurityLabel.of(:network, "example.com")
        c = SecurityLabel.of(:env, "API_KEY", Sensitivity::High)

        left = SecurityLabel.join(SecurityLabel.join(a, b), c)
        right = SecurityLabel.join(a, SecurityLabel.join(b, c))
        left.should eq right
      end

      it "joining a label with itself is idempotent" do
        a = SecurityLabel.of(:file, "/etc/hosts", Sensitivity::Elevated)
        SecurityLabel.join(a, a).should eq a
      end
    end

    describe "#sensitivity" do
      it "reflects the single worst tag among several" do
        l = SecurityLabel.new(Set{
          ProvenanceTag.new(:file, "/etc/hosts", Sensitivity::None),
          ProvenanceTag.new(:network, "example.com", Sensitivity::Elevated),
          ProvenanceTag.new(:env, "API_KEY", Sensitivity::High),
        })
        l.sensitivity.should eq Sensitivity::High
      end
    end
  end
end
