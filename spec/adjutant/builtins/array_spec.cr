require "../../spec_helper"

module Adjutant
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
      # (see SCOPE.md's Won't Fix); if that ever changes, this is the
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
  end
end
