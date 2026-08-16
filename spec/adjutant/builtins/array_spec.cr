require "../../spec_helper"

module Adjutant
  # Helper: a LabeledArray whose CONTAINER label is set directly (no
  # individual element carries it) — a minimal stand-in for a native
  # module labeling a whole container at once, mirroring
  # risk_flow_propagation_spec.cr's own `tainted`/`tainted_str`
  # helpers for scalars. Used by the container-level-label carry-
  # forward coverage below (select/reject/sort/reverse).
  private def self.make_tainted_array_interp(elements : Array(Int64)) : Interpreter
    interp, _ = make_interp
    interp.define_native("tainted_array") do |args|
      arr = LabeledArray.new(elements.map { |i| Value.int(i) })
      arr.label = RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
      Value.new(arr, nil)
    end
    interp
  end

  # Covers Phase 4b of the base-types work: Array. `[]`/`[]=` were
  # already real opcodes; `+`, `<<`, and `==` needed real fixes
  # alongside this class (ValueOps.add/shl/equal? had no Array case
  # at all before this session — genuine pre-existing gaps, not new
  # behavior), covered here as regression checks alongside the native
  # methods this file actually adds.
  describe "Array" do
    it "[1, 2].class is Array" do
      interp, _ = make_interp
      result = interp.eval("[1, 2].class == Array")
      result.truthy?.should be_true
    end

    it "[1, 2].is_a?(Array) is true" do
      interp, _ = make_interp
      result = interp.eval("[1, 2].is_a?(Array)")
      result.truthy?.should be_true
    end

    it "Array.superclass is Object" do
      interp, _ = make_interp
      result = interp.eval("Array.superclass == Object")
      result.truthy?.should be_true
    end

    describe "#length / #size" do
      it "both return the element count" do
        interp, _ = make_interp
        result = interp.eval("[[1, 2, 3].length, [1, 2, 3].size]")
        result.as_array.map(&.as_int).should eq [3, 3]
      end

      it "now resolves via Array's own native method, not just the generic fallback" do
        interp, _ = make_interp
        result = interp.eval("[1].respond_to?(:length)")
        result.truthy?.should be_true
      end
    end

    # Step 3 of the to_s/inspect overridability work (see
    # object_spec.cr's own header comment and DEVELOPMENT.md for the
    # full plan). `#to_s` here was previously a Crystal-level
    # `args.first.to_s` call — a circular no-op through the same
    # broken generic fallback `Object#inspect` guards against
    # (object_spec.cr) — so every case below is a real, previously-
    # broken behavior, not just new coverage of something that already
    # worked.
    describe "#to_s / #inspect" do
      it "to_s and inspect produce the same output — real Ruby aliases them for Array" do
        interp, _ = make_interp
        result = interp.eval("[[1, 2].to_s, [1, 2].inspect]")
        strs = result.as_array.map(&.as_string)
        strs[0].should eq strs[1]
      end

      it "an empty array renders as []" do
        interp, _ = make_interp
        interp.eval("[].to_s").as_string.should eq "[]"
      end

      it "elements render via THEIR OWN inspect, not to_s — a String element stays quoted even though the outer call is to_s" do
        interp, _ = make_interp
        interp.eval(%{[1, "a"].to_s}).as_string.should eq %{[1, "a"]}
      end

      it "a nested Array renders recursively" do
        interp, _ = make_interp
        interp.eval("[1, [2, 3]].to_s").as_string.should eq "[1, [2, 3]]"
      end

      it "a script class's own `def inspect` override is respected for an element, via real dispatch — not a hand-rolled per-type case" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        class A
          def inspect
            "custom!"
          end
        end
        [A.new].to_s
        RUBY
        result.as_string.should eq "[custom!]"
      end

      it "a plain object element with no override renders via Object's own default #inspect (ivar-listing, from step 1)" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        class A
          def initialize
            @x = 1
          end
        end
        [A.new].to_s
        RUBY
        result.as_string.should eq "[#<A @x=1>]"
      end

      it "a directly self-referential array renders as [[...]], matching real Ruby, instead of a native stack overflow" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        a = []
        a << a
        a.to_s
        RUBY
        result.as_string.should eq "[[...]]"
      end

      it "an indirect cycle (a contains b, b contains a) is also caught" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        a = []
        b = [a]
        a << b
        a.to_s
        RUBY
        result.as_string.should eq "[[[...]]]"
      end

      it "the cycle guard does not leak across unrelated inspect calls on the SAME array — inspecting it a second time still recurses normally" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        a = [1, 2]
        first = a.to_s
        second = a.to_s
        [first, second]
        RUBY
        strs = result.as_array.map(&.as_string)
        strs.should eq ["[1, 2]", "[1, 2]"]
      end

      it "the cycle guard does not leak after an element's own inspect raises mid-render — the SAME array can be inspected again afterward, not stuck reporting [...] forever" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        class Boom
          def inspect
            raise "boom"
          end
        end
        a = [Boom.new]
        begin
          a.to_s
        rescue RuntimeError
        end
        a[0] = 5
        a.to_s
        RUBY
        result.as_string.should eq "[5]"
      end
    end

    describe "#empty?" do
      it "true for an empty array" do
        interp, _ = make_interp
        result = interp.eval("[].empty?")
        result.truthy?.should be_true
      end

      it "false for a non-empty array" do
        interp, _ = make_interp
        result = interp.eval("[1].empty?")
        result.falsy?.should be_true
      end
    end

    describe "#push" do
      it "appends and returns self, mutating in place" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = [1]
          b = a.push(2)
          [a.length, b.length, a == b]
        RUBY
        arr = result.as_array
        arr[0].as_int.should eq 2
        arr[1].as_int.should eq 2
        arr[2].truthy?.should be_true
      end

      it "accepts multiple arguments, appending all of them" do
        interp, _ = make_interp
        result = interp.eval("[1].push(2, 3).length")
        result.as_int.should eq 3
      end

      it "joins a pushed value's label into the container's own label, matching << (opcode)" do
        interp, _ = make_interp
        interp.define_native("tainted_scalar") do |args|
          Value.int(9_i64, RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High))
        end
        result = interp.eval(<<-RUBY)
          a = [1]
          a.push(tainted_scalar)
          a
        RUBY
        result.label.should_not be_nil
      end
    end

    describe "#pop" do
      it "removes and returns the last element" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = [1, 2, 3]
          last = a.pop
          [last, a.length]
        RUBY
        arr = result.as_array
        arr[0].as_int.should eq 3
        arr[1].as_int.should eq 2
      end

      it "returns nil on an empty array, not an error" do
        interp, _ = make_interp
        result = interp.eval("[].pop")
        result.null?.should be_true
      end
    end

    describe "#include?" do
      it "true when a matching element is present, compared by value not identity" do
        interp, _ = make_interp
        result = interp.eval("[1, 2, 3].include?(2)")
        result.truthy?.should be_true
      end

      it "false when absent" do
        interp, _ = make_interp
        result = interp.eval("[1, 2, 3].include?(9)")
        result.falsy?.should be_true
      end

      it "uses deep equality for nested arrays as elements" do
        interp, _ = make_interp
        result = interp.eval("[[1, 2], [3, 4]].include?([1, 2])")
        result.truthy?.should be_true
      end
    end

    describe "#join" do
      it "joins elements with the given separator" do
        interp, _ = make_interp
        result = interp.eval(%([1, 2, 3].join(",")))
        result.as_string.should eq "1,2,3"
      end

      it "defaults to no separator when none is given" do
        interp, _ = make_interp
        result = interp.eval("[1, 2, 3].join")
        result.as_string.should eq "123"
      end

      it "renders nil elements as empty, not the word nil" do
        interp, _ = make_interp
        result = interp.eval(%([1, nil, 3].join(",")))
        result.as_string.should eq "1,,3"
      end
    end

    describe "#each" do
      it "invokes the block once per element, in order" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          sum = 0
          [1, 2, 3].each { |x| sum = sum + x }
          sum
        RUBY
        result.as_int.should eq 6
      end

      # Regression companion to proc_spec.cr's lambda closure-capture
      # fix (2026-07-20, see research/IFC_DESIGN.md's "VM propagation"
      # section and VM#invoke's own comment). That fix gave stored Proc
      # values their own real closure snapshot, called via a dedicated
      # VM#invoke_proc — Array#each's block never goes through that
      # path at all, it uses the plain VM#invoke a call-site block
      # literal always has, which always uses the CURRENT frame's
      # locals. THIS spec exists to confirm that path is still exactly
      # right, unchanged. Not expected to fail on its own — the spec
      # above already covers the basic same-frame case — but written
      # explicitly, with a nested method call in between, since a
      # native method's block invocation is architecturally guaranteed
      # same-frame only because Adjutant has no `&blk`-forwarding yet
      # (see UNSUPPORTED.md, U001); if that ever changes, this is the
      # spec that should start failing first.
      it "resolves an outer local from the defining frame even when reached through an intervening method call" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          def run_each(arr)
            sum = 0
            arr.each { |x| sum = sum + x }
            sum
          end
          run_each([10, 20, 30])
        RUBY
        result.as_int.should eq 60
      end

      it "returns the receiver itself" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = [1, 2, 3]
          (a.each { |x| x }) == a
        RUBY
        result.truthy?.should be_true
      end

      it "with no block, does not raise, and returns the receiver" do
        interp, _ = make_interp
        result = interp.eval("[1, 2, 3].each")
        result.as_array.map(&.as_int).should eq [1, 2, 3]
      end
    end

    describe "#map" do
      it "produces a new array of the block's return values" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          [1, 2, 3].map { |x| x * 2 }
        RUBY
        result.as_array.map(&.as_int).should eq [2, 4, 6]
      end

      it "does not mutate the receiver" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = [1, 2, 3]
          a.map { |x| x * 10 }
          a
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3]
      end
    end

    describe "opcode fixes: +, <<, == (regression checks for genuine pre-existing gaps)" do
      it "+ concatenates into a NEW array, leaving both operands untouched" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = [1, 2]
          b = [3, 4]
          c = a + b
          [c, a, b]
        RUBY
        arr = result.as_array
        arr[0].as_array.map(&.as_int).should eq [1, 2, 3, 4]
        arr[1].as_array.map(&.as_int).should eq [1, 2]
        arr[2].as_array.map(&.as_int).should eq [3, 4]
      end

      it "<< appends in place and returns self, so it chains" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = []
          a << 1 << 2 << 3
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3]
      end

      it "<< on an Integer still bit-shifts, unaffected by the Array overload" do
        interp, _ = make_interp
        result = interp.eval("1 << 3")
        result.as_int.should eq 8
      end

      it "== compares by value, element-wise, not by identity" do
        interp, _ = make_interp
        result = interp.eval("[1, 2, 3] == [1, 2, 3]")
        result.truthy?.should be_true
      end

      it "== is false for different lengths" do
        interp, _ = make_interp
        result = interp.eval("[1, 2] == [1, 2, 3]")
        result.falsy?.should be_true
      end

      it "== is false for different elements at the same position" do
        interp, _ = make_interp
        result = interp.eval("[1, 2, 3] == [1, 9, 3]")
        result.falsy?.should be_true
      end

      it "== recurses into nested arrays" do
        interp, _ = make_interp
        result = interp.eval("[[1], [2]] == [[1], [2]]")
        result.truthy?.should be_true
      end
    end

    describe "[]/[]= still work as existing opcodes, unaffected by this class landing" do
      it "reads an element by index" do
        interp, _ = make_interp
        result = interp.eval("[10, 20, 30][1]")
        result.as_int.should eq 20
      end

      it "writes an element by index" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = [10, 20, 30]
          a[1] = 99
          a
        RUBY
        result.as_array.map(&.as_int).should eq [10, 99, 30]
      end
    end

    it "indexes into an array" do
      eval("[10, 20, 30][1]").as_int.should eq 20_i64
    end

    it "indexes with negative index" do
      eval("[1, 2, 3][-1]").as_int.should eq 3_i64
    end

    it "assigns to an array index" do
      eval("a = [1, 2, 3]\na[0] = 99\na[0]").as_int.should eq 99_i64
    end

    describe "#first" do
      it "returns the first element" do
        eval("[1, 2, 3].first").as_int.should eq 1_i64
      end

      it "returns nil on an empty array" do
        eval("[].first").null?.should be_true
      end
    end

    describe "#last" do
      it "returns the last element" do
        eval("[1, 2, 3].last").as_int.should eq 3_i64
      end

      it "returns nil on an empty array" do
        eval("[].last").null?.should be_true
      end
    end

    describe "#select" do
      it "keeps elements for which the block is truthy" do
        eval(<<-RUBY).as_array.map(&.as_int).should eq [2, 4]
          [1, 2, 3, 4].select { |x| x.even? }
        RUBY
      end

      it "does not mutate the receiver" do
        eval(<<-RUBY).as_array.map(&.as_int).should eq [1, 2, 3]
          a = [1, 2, 3]
          a.select { |x| x.even? }
          a
        RUBY
      end

      it "with no block, returns an empty array" do
        eval("[1, 2, 3].select").as_array.empty?.should be_true
      end
    end

    describe "#reject" do
      it "drops elements for which the block is truthy" do
        eval(<<-RUBY).as_array.map(&.as_int).should eq [1, 3]
          [1, 2, 3, 4].reject { |x| x.even? }
        RUBY
      end

      it "does not mutate the receiver" do
        eval(<<-RUBY).as_array.map(&.as_int).should eq [1, 2, 3]
          a = [1, 2, 3]
          a.reject { |x| x.even? }
          a
        RUBY
      end
    end

    describe "#reduce / #inject" do
      it "reduces with an explicit initial value" do
        eval("[1, 2, 3].reduce(10) { |acc, x| acc + x }").as_int.should eq 16_i64
      end

      it "reduces with no initial value, using the first element as the seed" do
        eval("[1, 2, 3].reduce { |acc, x| acc + x }").as_int.should eq 6_i64
      end

      it "inject is an alias of reduce" do
        eval("[1, 2, 3].inject(0) { |acc, x| acc + x }").as_int.should eq 6_i64
      end

      it "with no initial value and an empty receiver, returns nil" do
        eval("[].reduce { |acc, x| acc + x }").null?.should be_true
      end

      it "with an explicit initial value and an empty receiver, returns the initial value" do
        eval("[].reduce(5) { |acc, x| acc + x }").as_int.should eq 5_i64
      end
    end

    describe "#sort" do
      it "sorts ascending by default" do
        eval("[3, 1, 2].sort").as_array.map(&.as_int).should eq [1, 2, 3]
      end

      it "does not mutate the receiver" do
        eval(<<-RUBY).as_array.map(&.as_int).should eq [3, 1, 2]
          a = [3, 1, 2]
          a.sort
          a
        RUBY
      end

      it "works on strings too, via the same comparison mechanism" do
        eval(%(["banana", "apple", "cherry"].sort)).as_array.map(&.as_string).should eq ["apple", "banana", "cherry"]
      end
    end

    describe "#reverse" do
      it "reverses element order" do
        eval("[1, 2, 3].reverse").as_array.map(&.as_int).should eq [3, 2, 1]
      end

      it "does not mutate the receiver" do
        eval(<<-RUBY).as_array.map(&.as_int).should eq [1, 2, 3]
          a = [1, 2, 3]
          a.reverse
          a
        RUBY
      end
    end

    describe "#min / #max" do
      it "min returns the smallest element" do
        eval("[3, 1, 2].min").as_int.should eq 1_i64
      end

      it "max returns the largest element" do
        eval("[3, 1, 2].max").as_int.should eq 3_i64
      end

      it "min on an empty array returns nil" do
        eval("[].min").null?.should be_true
      end

      it "max on an empty array returns nil" do
        eval("[].max").null?.should be_true
      end
    end

    describe "#any? / #all?" do
      it "any? with no block is true if any element is truthy" do
        eval("[nil, false, 1].any?").as_bool.should be_true
      end

      it "any? with no block is false if every element is falsy" do
        eval("[nil, false].any?").as_bool.should be_false
      end

      it "any? with a block tests the block's return value" do
        eval("[1, 2, 3].any? { |x| x > 2 }").as_bool.should be_true
      end

      it "all? with no block is true if every element is truthy" do
        eval("[1, 2, 3].all?").as_bool.should be_true
      end

      it "all? with no block is false if any element is falsy" do
        eval("[1, nil, 3].all?").as_bool.should be_false
      end

      it "all? with a block tests the block's return value" do
        eval("[2, 4, 6].all? { |x| x.even? }").as_bool.should be_true
      end

      it "all? on an empty array is true (vacuous truth)" do
        eval("[].all?").as_bool.should be_true
      end
    end

    describe "container-level risk label carries forward through select/reject/sort/reverse/map" do
      # research/IFC_DESIGN.md's Container labeling (Stage 3.5): a
      # LabeledArray has its OWN accumulated label, distinct from any
      # individual element's — e.g. set directly via
      # declare_sensitivity on the container itself, with no single
      # element carrying it. A method that builds a new container
      # from a subset/reordering of the original must carry that
      # container-level label forward, not just re-derive one from
      # the kept elements' own labels, or it would silently drop
      # taint the design doc's "monotonic, fails safe" principle says
      # should persist. See `make_tainted_array_interp` at the top of
      # this file for how the container-level-only label is set up.
      it "select carries forward the receiver's container-level label even when no kept element has its own" do
        interp = make_tainted_array_interp([1_i64, 2_i64, 3_i64])
        result = interp.eval("tainted_array.select { |x| x > 1 }")
        result.label.should_not be_nil
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "reject carries forward the receiver's container-level label" do
        interp = make_tainted_array_interp([1_i64, 2_i64])
        result = interp.eval("tainted_array.reject { |x| x > 1 }")
        result.label.should_not be_nil
      end

      it "sort carries forward the receiver's container-level label" do
        interp = make_tainted_array_interp([3_i64, 1_i64, 2_i64])
        result = interp.eval("tainted_array.sort")
        result.label.should_not be_nil
      end

      it "reverse carries forward the receiver's container-level label" do
        interp = make_tainted_array_interp([1_i64, 2_i64])
        result = interp.eval("tainted_array.reverse")
        result.label.should_not be_nil
      end

      it "map carries forward the receiver's container-level label even though every element is a brand new computed value" do
        interp = make_tainted_array_interp([1_i64, 2_i64])
        result = interp.eval("tainted_array.map { |x| x * 10 }")
        result.label.should_not be_nil
      end
    end
  end
end
