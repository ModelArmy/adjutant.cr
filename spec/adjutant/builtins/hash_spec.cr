require "../../spec_helper"

module Adjutant
  # Covers Phase 4c of the base-types work: Hash, the last piece of
  # Phase 4. `[]`/`[]=` were already real opcodes; `==` (same key set,
  # each value compared via values_equal?) was extended alongside
  # Array's own bootstrap last phase and is covered there, not
  # repeated here.
  #
  # Only `{"k" => v}` (hash-rocket) literal syntax is supported —
  # `{k: v}` (symbol-shorthand) isn't parsed at all yet (see
  # DEVELOPMENT.md), so every literal in this file uses hash-rocket.
  describe "Hash" do
    it %({"a" => 1}.class is Hash) do
      interp, _ = make_interp
      result = interp.eval(%({"a" => 1}.class == Hash))
      result.truthy?.should be_true
    end

    it %({"a" => 1}.is_a?(Hash) is true) do
      interp, _ = make_interp
      result = interp.eval(%({"a" => 1}.is_a?(Hash)))
      result.truthy?.should be_true
    end

    it "Hash.superclass is Object" do
      interp, _ = make_interp
      result = interp.eval("Hash.superclass == Object")
      result.truthy?.should be_true
    end

    describe "#length / #size" do
      it "both return the pair count" do
        interp, _ = make_interp
        result = interp.eval(%([{"a" => 1, "b" => 2}.length, {"a" => 1, "b" => 2}.size]))
        result.as_array.map(&.as_int).should eq [2, 2]
      end

      it "now resolves via Hash's own native method, not just the generic fallback" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.respond_to?(:length)))
        result.truthy?.should be_true
      end
    end

    describe "#empty?" do
      it "true for an empty hash" do
        interp, _ = make_interp
        result = interp.eval("{}.empty?")
        result.truthy?.should be_true
      end

      it "false for a non-empty hash" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.empty?))
        result.falsy?.should be_true
      end
    end

    describe "#keys / #values" do
      it "keys returns a real Array of the keys" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1, "b" => 2}.keys))
        result.as_array.map(&.as_string).should eq ["a", "b"]
      end

      it "values returns a real Array of the values, same order as keys" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1, "b" => 2}.values))
        result.as_array.map(&.as_int).should eq [1, 2]
      end
    end

    describe "#key? / #include? / #has_key? — three names for the same check" do
      it "key? is true for a present key" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.key?("a")))
        result.truthy?.should be_true
      end

      it "key? is false for an absent key" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.key?("z")))
        result.falsy?.should be_true
      end

      it "include? and has_key? agree with key? on the same hash" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1}
          [h.key?("a"), h.include?("a"), h.has_key?("a")]
        RUBY
        result.as_array.map(&.truthy?).should eq [true, true, true]
      end
    end

    describe "#each" do
      it "invokes the block once per key/value pair, destructured positionally" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          sum = 0
          {"a" => 1, "b" => 2, "c" => 3}.each { |k, v| sum = sum + v }
          sum
        RUBY
        result.as_int.should eq 6
      end

      it "returns the receiver itself" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1}
          (h.each { |k, v| v }) == h
        RUBY
        result.truthy?.should be_true
      end

      it "with no block, does not raise, and returns the receiver" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.each))
        result.hash?.should be_true
      end
    end

    describe "[]/[]= still work as existing opcodes, unaffected by this class landing" do
      it "reads a value by key" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1, "b" => 2}["b"]))
        result.as_int.should eq 2
      end

      it "returns nil for a missing key, not an error" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}["z"]))
        result.null?.should be_true
      end

      it "writes a value by key" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1}
          h["b"] = 2
          h["b"]
        RUBY
        result.as_int.should eq 2
      end
    end

    describe "cross-type numeric key lookup" do
      # Verified behavior, not assumed: Crystal's Int64/Float64#hash
      # are cross-type consistent (5.hash == 5.0.hash when 5 == 5.0),
      # so a Hash(Value, Value) keyed by an Integer IS found by a
      # numerically-equal Float lookup, matching values_equal?'s own
      # notion of equality. An earlier draft of this spec assumed the
      # opposite (that Crystal's struct hash would diverge here) —
      # this was wrong, caught by the test itself, not by re-reading
      # documentation. Kept as a positive regression test now that
      # it's confirmed correct, since it's the kind of behavior that's
      # easy to accidentally break (e.g. by adding a custom Value#hash
      # override later that ISN'T cross-type consistent).
      it "an Integer key IS found via a numerically-equal Float lookup" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {5 => "a"}
          [h[5], h[5.0], (5 == 5.0)]
        RUBY
        arr = result.as_array
        arr[0].as_string.should eq "a"
        arr[1].as_string.should eq "a"
        arr[2].truthy?.should be_true
      end
    end
  end
end
