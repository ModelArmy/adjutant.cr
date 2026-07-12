require "../spec_helper"

module Adjutant
  describe LabeledArray do
    it "starts with no label by default" do
      LabeledArray.new.label.should be_nil
    end

    it "size and [] back element access, to_a for enumeration" do
      arr = LabeledArray.new([Value.int(1_i64), Value.int(2_i64), Value.int(3_i64)])
      arr.size.should eq 3
      arr[0].as_int.should eq 1_i64
      arr.to_a.map(&.as_int).should eq [1_i64, 2_i64, 3_i64]
    end

    it "map returns a plain Array, not a LabeledArray" do
      arr = LabeledArray.new([Value.int(1_i64), Value.int(2_i64)])
      mapped = arr.map(&.as_int)
      mapped.should be_a(Array(Int64))
      mapped.should eq [1_i64, 2_i64]
    end

    it "[]? returns nil for an out-of-bounds index instead of raising" do
      arr = LabeledArray.new([Value.int(1_i64)])
      arr[1]?.should be_nil
      arr[0]?.not_nil!.as_int.should eq 1_i64
    end

    it "empty? reflects whether any items are present" do
      LabeledArray.new.empty?.should be_true
      LabeledArray.new([Value.int(1_i64)]).empty?.should be_false
    end

    it "any? matches Array#any? semantics" do
      arr = LabeledArray.new([Value.int(1_i64), Value.int(2_i64)])
      arr.any? { |v| v.as_int == 2_i64 }.should be_true
      arr.any? { |v| v.as_int == 99_i64 }.should be_false
    end

    it "zip compares two same-length arrays element-wise via the given block" do
      a = LabeledArray.new([Value.int(1_i64), Value.int(2_i64)])
      b = LabeledArray.new([Value.int(1_i64), Value.int(2_i64)])
      c = LabeledArray.new([Value.int(1_i64), Value.int(99_i64)])
      a.zip(b) { |x, y| x.as_int == y.as_int }.should be_true
      a.zip(c) { |x, y| x.as_int == y.as_int }.should be_false
    end

    it "push mutates in place and is visible through any reference to the same object" do
      arr = LabeledArray.new
      alias_ref = arr
      arr.push(Value.int(1_i64))
      alias_ref.size.should eq 1
    end

    it "pop removes and returns the last element" do
      arr = LabeledArray.new([Value.int(1_i64), Value.int(2_i64)])
      arr.pop.as_int.should eq 2_i64
      arr.size.should eq 1
    end

    it "pop? returns nil instead of raising when empty" do
      LabeledArray.new.pop?.should be_nil
    end

    it "[]= mutates the underlying element" do
      arr = LabeledArray.new([Value.int(1_i64)])
      arr[0] = Value.int(99_i64)
      arr[0].as_int.should eq 99_i64
    end

    it "label is mutable and shared by reference" do
      arr = LabeledArray.new
      alias_ref = arr
      arr.label = SecurityLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
      alias_ref.label.not_nil!.sensitivity.should eq Sensitivity::High
    end

    it "dup_items returns an independent copy" do
      arr = LabeledArray.new([Value.int(1_i64)])
      items = arr.dup_items
      items << Value.int(2_i64)
      arr.size.should eq 1
    end
  end

  describe LabeledHash do
    it "starts with no label by default" do
      LabeledHash.new.label.should be_nil
    end

    it "supports size, []=, [], has_key?, keys, values, empty?" do
      h = LabeledHash.new
      h.empty?.should be_true
      h[Value.string("a")] = Value.int(1_i64)
      h.size.should eq 1
      h.empty?.should be_false
      h[Value.string("a")].as_int.should eq 1_i64
      h.has_key?(Value.string("a")).should be_true
      h.has_key?(Value.string("b")).should be_false
      h.keys.map(&.as_string).should eq ["a"]
      h.values.map(&.as_int).should eq [1_i64]
    end

    it "[]? returns nil for a missing key instead of raising" do
      h = LabeledHash.new
      h[Value.string("missing")]?.should be_nil
    end

    it "each yields key and value" do
      h = LabeledHash.new
      h[Value.string("a")] = Value.int(1_i64)
      pairs = [] of {Value, Value}
      h.each { |k, v| pairs << {k, v} }
      pairs.size.should eq 1
      pairs.first[0].as_string.should eq "a"
      pairs.first[1].as_int.should eq 1_i64
    end

    it "label mutation is shared by reference" do
      h = LabeledHash.new
      alias_ref = h
      h.label = SecurityLabel.of(ProvenanceKind::Network, "example.com")
      alias_ref.label.should_not be_nil
    end

    it "dup_entries returns an independent copy" do
      h = LabeledHash.new
      h[Value.string("a")] = Value.int(1_i64)
      entries = h.dup_entries
      entries[Value.string("b")] = Value.int(2_i64)
      h.size.should eq 1
    end
  end

  describe "Value construction over LabeledArray/LabeledHash" do
    it "array? / hash? predicates work against the new wrapper types" do
      Value.new(LabeledArray.new, nil).array?.should be_true
      Value.new(LabeledHash.new, nil).hash?.should be_true
    end

    it "Value.array wraps values in a LabeledArray with the given label" do
      l = SecurityLabel.of(ProvenanceKind::File, "/etc/hosts")
      v = Value.array(Value.int(1_i64), Value.int(2_i64), label: l)
      v.array?.should be_true
      v.as_array.size.should eq 2
      v.label.should eq l
    end

    describe "computed #label for containers" do
      it "reflects the live LabeledArray label, not a stale copy" do
        arr = LabeledArray.new
        v = Value.new(arr, nil)
        v.label.should be_nil
        arr.label = SecurityLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
        # Same Value struct instance still reflects the mutation, since
        # #label is computed from the live container, not a stored field.
        v.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "an old copy of a container Value also reflects later mutation" do
        arr = LabeledArray.new
        v1 = Value.new(arr, nil)
        v2 = v1 # struct copy, same underlying LabeledArray
        arr.label = SecurityLabel.of(ProvenanceKind::Network, "example.com")
        v2.label.should_not be_nil
      end
    end

    describe "#with_label on containers" do
      it "sets the label on the underlying LabeledArray rather than being ignored" do
        v = Value.new(LabeledArray.new, nil)
        labeled = v.with_label(SecurityLabel.of(ProvenanceKind::File, "/etc/hosts"))
        labeled.label.should_not be_nil
        # And it's visible on the original Value too, since it's the same container.
        v.label.should_not be_nil
      end

      it "sets the label on the underlying LabeledHash rather than being ignored" do
        v = Value.new(LabeledHash.new, nil)
        labeled = v.with_label(SecurityLabel.of(ProvenanceKind::File, "/etc/hosts"))
        labeled.label.should_not be_nil
        v.label.should_not be_nil
      end
    end
  end
end
