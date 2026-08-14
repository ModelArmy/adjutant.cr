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

    it "to_s with a base argument renders in that radix" do
      eval("10.to_s(2)").as_string.should eq "1010"
      eval("10.to_s(36)").as_string.should eq "a"
      eval("(-10).to_s(36)").as_string.should eq "-a"
      eval("12345.to_s(8)").as_string.should eq "30071"
    end

    it "to_s with base 10 explicitly matches the default rendering" do
      eval("12345.to_s(10)").as_string.should eq "12345"
    end

    it "to_s rejects a base outside 2..36 with a script-catchable ArgumentError" do
      interp, _ = make_interp
      error = expect_raises(RuntimeError) do
        interp.eval("10.to_s(-1)")
      end
      diag = error.diagnostic.not_nil!
      diag.code.should eq("R015")
      diag.data["base"].should eq("-1")
    end

    it "to_s rejects base 0, base 1, and base 37 the same way" do
      interp, _ = make_interp
      [0, 1, 37].each do |base|
        error = expect_raises(RuntimeError) do
          interp.eval("10.to_s(#{base})")
        end
        error.diagnostic.not_nil!.code.should eq("R015")
      end
    end

    it "to_s's ArgumentError is rescuable from script" do
      eval(<<-RUBY).as_bool.should be_true
        begin
          10.to_s(-1)
          false
        rescue ArgumentError
          true
        end
      RUBY
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

    it "ceil/floor/round/truncate with a non-negative ndigits are still no-ops" do
      eval("12345.ceil(2)").as_int.should eq 12345_i64
      eval("12345.floor(0)").as_int.should eq 12345_i64
    end

    describe "ceil/floor/round/truncate with a negative ndigits" do
      it "round rounds to the nearest power of 10" do
        eval("12345.round(-2)").as_int.should eq 12300_i64
        eval("12350.round(-2)").as_int.should eq 12400_i64
      end

      it "round on a negative receiver rounds ties away from zero" do
        eval("(-12350).round(-2)").as_int.should eq(-12400_i64)
      end

      it "ceil rounds toward positive infinity" do
        eval("12341.ceil(-2)").as_int.should eq 12400_i64
        eval("(-12341).ceil(-2)").as_int.should eq(-12300_i64)
      end

      it "floor rounds toward negative infinity" do
        eval("12399.floor(-2)").as_int.should eq 12300_i64
        eval("(-12399).floor(-2)").as_int.should eq(-12400_i64)
      end

      it "truncate rounds toward zero" do
        eval("12399.truncate(-2)").as_int.should eq 12300_i64
        eval("(-12399).truncate(-2)").as_int.should eq(-12300_i64)
      end
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
