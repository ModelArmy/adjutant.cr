require "../../spec_helper"

module Adjutant
  describe "Builtins::Integer" do
    it "is registered as a real RubyClass reachable from script" do
      val = eval("Integer")
      val.rclass?.should be_true
      val.as_rclass.name.should eq "Integer"
    end

    it "5.is_a?(Integer) is true against the real class" do
      eval("5.is_a?(Integer)").as_bool.should be_true
    end

    it "5.is_a?(String) is false" do
      eval(%(5.is_a?(Exception))).as_bool.should be_false
    end

    it "to_s dispatches through the native method, not just the generic fallback" do
      eval("5.to_s").as_string.should eq "5"
    end

    it "to_i on an integer returns itself" do
      eval("5.to_i").as_int.should eq 5_i64
    end

    it "to_f converts to a float" do
      eval("5.to_f").as_float.should eq 5.0
    end

    it "arithmetic still works via VM opcodes, unaffected by native methods" do
      eval("2 + 3").as_int.should eq 5_i64
    end

    it "succ returns the next integer" do
      eval("5.succ").as_int.should eq 6_i64
    end

    it "next is an alias of succ" do
      eval("5.next").as_int.should eq 6_i64
    end

    it "succ/next work on negative integers too" do
      eval("(-1).succ").as_int.should eq 0_i64
    end

    it "abs returns the absolute value" do
      eval("(-5).abs").as_int.should eq 5_i64
    end

    it "abs on a positive integer returns itself" do
      eval("5.abs").as_int.should eq 5_i64
    end

    it "even? is true for even integers" do
      eval("4.even?").as_bool.should be_true
    end

    it "even? is false for odd integers" do
      eval("5.even?").as_bool.should be_false
    end

    it "odd? is true for odd integers" do
      eval("5.odd?").as_bool.should be_true
    end

    it "odd? is false for even integers" do
      eval("4.odd?").as_bool.should be_false
    end

    it "zero? is true for zero" do
      eval("0.zero?").as_bool.should be_true
    end

    it "zero? is false for a non-zero integer" do
      eval("5.zero?").as_bool.should be_false
    end

    it "times yields each integer from 0 up to (excluding) self" do
      eval(<<-RUBY).as_array.map(&.as_int).should eq [0, 1, 2]
        result = []
        3.times { |i| result.push(i) }
        result
      RUBY
    end

    it "times returns the receiver" do
      eval("3.times { |i| i }").as_int.should eq 3_i64
    end

    it "times with no block is a no-op that returns the receiver" do
      eval("3.times").as_int.should eq 3_i64
    end

    it "times on zero yields nothing" do
      eval(<<-RUBY).as_array.empty?.should be_true
        result = []
        0.times { |i| result.push(i) }
        result
      RUBY
    end

    it "ceil with no args returns the receiver" do
      eval("5.ceil").as_int.should eq 5_i64
    end

    it "floor with no args returns the receiver" do
      eval("5.floor").as_int.should eq 5_i64
    end

    it "round with no args returns the receiver" do
      eval("5.round").as_int.should eq 5_i64
    end

    it "truncate with no args returns the receiver" do
      eval("5.truncate").as_int.should eq 5_i64
    end

    it "ceil/floor/round/truncate work on negative integers too" do
      eval("(-5).ceil").as_int.should eq(-5_i64)
      eval("(-5).floor").as_int.should eq(-5_i64)
      eval("(-5).round").as_int.should eq(-5_i64)
      eval("(-5).truncate").as_int.should eq(-5_i64)
    end

    it "every builtin Integer method defaults to RiskProfile.none" do
      interp, _ = make_interp
      cls = interp.get_global("Integer").as_rclass
      %w[to_s to_i to_f succ next abs even? odd? zero? times ceil floor round truncate].each do |name|
        sym_id = interp.symbols.lookup(name).not_nil!.value
        cls.find_native_method(sym_id).not_nil!.risk.should eq RiskProfile.none
      end
    end
  end
end
