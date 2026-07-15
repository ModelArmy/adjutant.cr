require "../../spec_helper"

module Adjutant
  # Range: a real RubyObject (@__min/@__max/@__exclusive ivars)
  # backing `1..5`/`1...5` literals (see Op::MakeRange in vm.cr),
  # replacing the earlier `[start, end, exclusive_flag]` LabeledArray
  # stand-in noted in research/IFC_DESIGN.md and the 2026-07-14
  # handoff. #each is implemented via #succ (see Integer#succ in
  # integer_spec.cr), matching real Ruby's own Range#each rather than
  # hardcoding "is this an Integer range" — any bound type with a
  # #succ and an orderable comparison (see NativeCallContext#compare)
  # works the same way.
  #
  # for-loop-over-a-Range integration (compile_for's `expr.each`
  # desugar) is covered in vm_spec.cr's "for loop"/"Range" describe
  # blocks alongside the other for/while loop-construct specs, not
  # here — this file is about Range's own native methods in
  # isolation.
  describe "Range" do
    it "1..5.class is Range" do
      eval("(1..5).class == Range").truthy?.should be_true
    end

    it "1..5.is_a?(Range) is true" do
      eval("(1..5).is_a?(Range)").truthy?.should be_true
    end

    it "is not an Array" do
      eval("(1..5).is_a?(Array)").falsy?.should be_true
    end

    describe "#min / #max / #first / #last" do
      it "returns the range's bounds" do
        result = eval("[(2..7).min, (2..7).max, (2..7).first, (2..7).last]")
        result.as_array.map(&.as_int).should eq [2, 7, 2, 7]
      end
    end

    describe "#exclusive?" do
      it "is false for .." do
        eval("(1..5).exclusive?").as_bool.should be_false
      end

      it "is true for ..." do
        eval("(1...5).exclusive?").as_bool.should be_true
      end
    end

    describe "#to_s" do
      it "renders an inclusive range with .." do
        eval("(1..5).to_s").as_string.should eq "1..5"
      end

      it "renders an exclusive range with ..." do
        eval("(1...5).to_s").as_string.should eq "1...5"
      end
    end

    describe "#include?" do
      it "true for a value within bounds" do
        eval("(1..5).include?(3)").truthy?.should be_true
      end

      it "true for the max bound when inclusive" do
        eval("(1..5).include?(5)").truthy?.should be_true
      end

      it "false for the max bound when exclusive" do
        eval("(1...5).include?(5)").falsy?.should be_true
      end

      it "false for a value below the min bound" do
        eval("(1..5).include?(0)").falsy?.should be_true
      end
    end

    describe "#each" do
      it "yields every value, inclusive of max for .." do
        result = eval(<<-RUBY)
          seen = []
          (1..4).each { |n| seen << n }
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3, 4]
      end

      it "excludes max for ..." do
        result = eval(<<-RUBY)
          seen = []
          (1...4).each { |n| seen << n }
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3]
      end

      it "yields nothing when min > max" do
        result = eval(<<-RUBY)
          seen = []
          (5..1).each { |n| seen << n }
          seen
        RUBY
        result.as_array.should be_empty
      end

      it "returns the receiver, matching real Ruby" do
        result = eval(<<-RUBY)
          r = 1..3
          (r.each { |n| n }).equal?(r)
        RUBY
        result.as_bool.should be_true
      end

      it "with no block, does not raise, and returns the receiver" do
        result = eval("(1..3).each")
        result.as_robject.rclass.name.should eq "Range"
      end
    end

    it "every builtin Range method defaults to RiskProfile.none" do
      interp, _ = make_interp
      cls = interp.get_global("Range").as_rclass
      %w[min max first last exclusive? to_s include? each].each do |name|
        sym_id = interp.symbols.lookup(name).not_nil!.value
        cls.find_native_method(sym_id).not_nil!.risk.should eq RiskProfile.none
      end
    end
  end
end
