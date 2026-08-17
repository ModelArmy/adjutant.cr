require "../../spec_helper"

module Adjutant
  # Helper: a LabeledHash whose CONTAINER label is set directly (no
  # individual key/value carries it) — Hash-side counterpart to
  # array_spec.cr's own `make_tainted_array_interp`.
  private def self.make_tainted_hash_interp(pairs : Hash(String, Int64)) : Interpreter
    interp, _ = make_interp
    interp.define_native("tainted_hash") do |args|
      entries = {} of Value => Value
      pairs.each { |k, v| entries[Value.string(k)] = Value.int(v) }
      h = LabeledHash.new(entries)
      h.label = RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
      Value.new(h, nil)
    end
    interp
  end

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

    # Step 4 of the to_s/inspect overridability work (see
    # object_spec.cr's own header comment and DEVELOPMENT.md for the
    # full plan). `#to_s` here was previously a Crystal-level
    # `args.first.to_s` call — the same broken circular no-op Array's
    # own pre-fix `#to_s` had — so every case below is a real,
    # previously-broken behavior.
    describe "#to_s / #inspect" do
      it "to_s and inspect produce the same output — real Ruby aliases them for Hash, same as Array" do
        interp, _ = make_interp
        result = interp.eval(%([{"a" => 1}.to_s, {"a" => 1}.inspect]))
        strs = result.as_array.map(&.as_string)
        strs[0].should eq strs[1]
      end

      it "an empty hash renders as {}" do
        interp, _ = make_interp
        interp.eval("{}.to_s").as_string.should eq "{}"
      end

      it "a single string-keyed pair renders as \"key\" => value, both via real inspect" do
        interp, _ = make_interp
        interp.eval(%({"a" => 1}.to_s)).as_string.should eq %({"a" => 1})
      end

      it "multiple pairs join with a comma-space, insertion order" do
        interp, _ = make_interp
        interp.eval(%({"a" => 1, "b" => 2}.to_s)).as_string.should eq %({"a" => 1, "b" => 2})
      end

      it "values render via THEIR OWN inspect, not to_s — a String value stays quoted" do
        interp, _ = make_interp
        interp.eval(%({"a" => "hi"}.to_s)).as_string.should eq %({"a" => "hi"})
      end

      it "a nested Hash value renders recursively" do
        interp, _ = make_interp
        interp.eval(%({"a" => {"b" => 1}}.to_s)).as_string.should eq %({"a" => {"b" => 1}})
      end

      it "a nested Array value renders recursively, via the SAME cycle-guard mechanism Array uses" do
        interp, _ = make_interp
        interp.eval(%({"a" => [1, 2]}.to_s)).as_string.should eq %({"a" => [1, 2]})
      end

      it "a Symbol key that's a plain identifier uses the shorthand name: value notation, matching real Ruby" do
        interp, _ = make_interp
        interp.eval(%({name: "x"}.to_s)).as_string.should eq %({name: "x"})
      end

      it "multiple plain-identifier Symbol keys each use the shorthand" do
        interp, _ = make_interp
        interp.eval(%({name: "x", age: 5}.to_s)).as_string.should eq %({name: "x", age: 5})
      end

      it "a Symbol key ending in ? or ! still uses the shorthand" do
        interp, _ = make_interp
        interp.eval(%({valid?: true}.to_s)).as_string.should eq %({valid?: true})
      end

      it "a Symbol key that ISN'T a plain identifier (contains a space) still uses colon-shorthand, with the name quoted like a String — confirmed against a real irb session, NOT hash-rocket" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        h = {}
        h[:"foo bar"] = 1
        h.to_s
        RUBY
        result.as_string.should eq %({"foo bar": 1})
      end

      it "the shorthand depends only on the key's type and name, not which literal syntax built the Hash — a hash-rocket-written symbol key renders identically to a shorthand-written one" do
        interp, _ = make_interp
        interp.eval(%({"a" => 5, b: 6, :c => 8}.to_s)).as_string.should eq %({"a" => 5, b: 6, c: 8})
      end

      it "a non-Symbol key never uses the shorthand, even a String that looks like an identifier" do
        interp, _ = make_interp
        interp.eval(%({"name" => "x"}.to_s)).as_string.should eq %({"name" => "x"})
      end

      it "a script class's own `def inspect` override is respected for a value, via real dispatch" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        class A
          def inspect
            "custom!"
          end
        end
        {"a" => A.new}.to_s
        RUBY
        result.as_string.should eq %({"a" => custom!})
      end

      it "a plain object value with no override renders via Object's own default #inspect (ivar-listing, from step 1)" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        class A
          def initialize
            @x = 1
          end
        end
        {"a" => A.new}.to_s
        RUBY
        result.as_string.should eq %({"a" => #<A @x=1>})
      end

      it "a directly self-referential hash value renders as {...}, matching real Ruby, instead of a native stack overflow" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        h = {}
        h["self"] = h
        h.to_s
        RUBY
        result.as_string.should eq %({"self" => {...}})
      end

      it "a cycle running through an Array is caught by the SAME shared guard, not Hash-specific tracking" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        a = []
        h = {"a" => a}
        a << h
        h.to_s
        RUBY
        result.as_string.should eq %({"a" => [{...}]})
      end

      it "the cycle guard does not leak across unrelated inspect calls on the SAME hash" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        h = {"a" => 1}
        first = h.to_s
        second = h.to_s
        [first, second]
        RUBY
        strs = result.as_array.map(&.as_string)
        strs.should eq [%({"a" => 1}), %({"a" => 1})]
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

    it "indexes into a hash" do
      eval(%({ "k" => 42 }["k"])).as_int.should eq 42_i64
    end

    describe "#delete" do
      it "removes the key and returns its value" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1, "b" => 2}
          [h.delete("a"), h.key?("a"), h.size]
        RUBY
        arr = result.as_array
        arr[0].as_int.should eq 1
        arr[1].falsy?.should be_true
        arr[2].as_int.should eq 1
      end

      it "returns nil for an absent key, with no block" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.delete("z")))
        result.null?.should be_true
      end

      it "with a block, calls it with the missing key when absent" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.delete("z") { |k| k + "!" }))
        result.as_string.should eq "z!"
      end

      it "does not call the block when the key IS present" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.delete("a") { |k| "should not run" }))
        result.as_int.should eq 1
      end
    end

    describe "#to_a" do
      it "converts each entry into a [key, value] pair" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1, "b" => 2}.to_a))
        arr = result.as_array
        arr.size.should eq 2
        arr[0].as_array.map(&.to_s).should eq ["a", "1"]
        arr[1].as_array.map(&.to_s).should eq ["b", "2"]
      end

      it "on an empty hash returns an empty array" do
        interp, _ = make_interp
        result = interp.eval("{}.to_a")
        result.as_array.empty?.should be_true
      end
    end

    describe "#merge" do
      it "returns a new hash, without mutating the receiver" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h1 = {"a" => 1}
          h2 = {"b" => 2}
          h3 = h1.merge(h2)
          [h1.key?("b"), h3["a"], h3["b"]]
        RUBY
        arr = result.as_array
        arr[0].falsy?.should be_true
        arr[1].as_int.should eq 1
        arr[2].as_int.should eq 2
      end

      it "a later argument's duplicate key overrides an earlier one, including the receiver's own" do
        interp, _ = make_interp
        result = interp.eval(%({"a" => 1}.merge({"a" => 2})["a"]))
        result.as_int.should eq 2
      end

      it "accepts multiple Hash arguments" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1}.merge({"b" => 2}, {"c" => 3})
          [h["a"], h["b"], h["c"]]
        RUBY
        arr = result.as_array
        arr.map(&.as_int).should eq [1, 2, 3]
      end

      it "with a block, resolves conflicts via the block instead of a plain override" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h1 = {"a" => 1}
          h2 = {"a" => 2}
          h1.merge(h2) { |key, old_val, new_val| old_val + new_val }["a"]
        RUBY
        result.as_int.should eq 3
      end

      it "raises TypeError for a non-Hash argument" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval(%({"a" => 1}.merge(5))) }
        error.diagnostic.not_nil!.code.should eq("R017")
      end

      it "TypeError is rescuable from script" do
        eval(<<-RUBY).as_bool.should be_true
          begin
            {"a" => 1}.merge(5)
            false
          rescue TypeError
            true
          end
        RUBY
      end
    end

    describe "container-level risk label carries forward through delete/to_a/merge" do
      # research/IFC_DESIGN.md's Container labeling (Stage 3.5) —
      # same principle already applied to Array's own select/reject/
      # sort/reverse/map (array_spec.cr). `tainted_hash` returns a
      # LabeledHash whose CONTAINER label is set directly (no
      # individual key/value carries it) — see the module-level
      # `make_tainted_hash_interp` helper at the top of this file.
      it "to_a carries forward the receiver's container-level label" do
        interp = make_tainted_hash_interp({"a" => 1_i64})
        result = interp.eval("tainted_hash.to_a")
        result.label.should_not be_nil
      end

      it "merge carries forward BOTH the receiver's and the argument's container-level label" do
        interp = make_tainted_hash_interp({"a" => 1_i64})
        interp.define_native("plain_hash") do |args|
          Value.new(LabeledHash.new({Value.string("b") => Value.int(2_i64)}), nil)
        end
        result = interp.eval("plain_hash.merge(tainted_hash)")
        result.label.should_not be_nil
      end
    end
  end
end
