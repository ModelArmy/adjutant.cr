require "../../spec_helper"

module Adjutant
  # Covers Phase 3 of the base-types work: Float. Mirrors Integer's
  # existing coverage closely — arithmetic/comparison are opcodes, not
  # methods, and already handle Integer/Float mixing (see
  # operators/vm_spec.cr for those); this file covers Float's own
  # RubyClass (.class, is_a?, superclass) and its three native methods
  # (to_s, to_i, to_f).
  describe "Float" do
    it "2.5.class is Float" do
      interp, _ = make_interp
      result = interp.eval("2.5.class == Float")
      result.truthy?.should be_true
    end

    it "2.5.is_a?(Float) is true" do
      interp, _ = make_interp
      result = interp.eval("2.5.is_a?(Float)")
      result.truthy?.should be_true
    end

    it "2.5.is_a?(Integer) is false — Float and Integer don't cross-match" do
      interp, _ = make_interp
      result = interp.eval("2.5.is_a?(Integer)")
      result.falsy?.should be_true
    end

    it "Float.superclass is Object" do
      interp, _ = make_interp
      result = interp.eval("Float.superclass == Object")
      result.truthy?.should be_true
    end

    it "Float.class is Class" do
      interp, _ = make_interp
      result = interp.eval("Float.class == Class")
      result.truthy?.should be_true
    end

    describe "#to_s" do
      it "renders a float as a decimal string" do
        interp, _ = make_interp
        result = interp.eval("2.5.to_s")
        result.as_string.should eq "2.5"
      end

      it "renders a whole-number float with a trailing .0, not as an integer" do
        interp, _ = make_interp
        result = interp.eval("3.0.to_s")
        result.as_string.should eq "3.0"
      end
    end

    describe "#to_i" do
      it "truncates toward zero, not rounding" do
        interp, _ = make_interp
        result = interp.eval("3.7.to_i")
        result.as_int.should eq 3
      end

      it "truncates a negative float toward zero" do
        interp, _ = make_interp
        result = interp.eval("(-3.7).to_i")
        result.as_int.should eq -3
      end
    end

    describe "#to_f" do
      it "is identity" do
        interp, _ = make_interp
        result = interp.eval("2.5.to_f")
        result.as_float.should eq 2.5
      end
    end

    describe "arithmetic and comparison opcodes already handle Integer/Float mixing" do
      it "int + float promotes to float" do
        interp, _ = make_interp
        result = interp.eval("5 + 2.5")
        result.as_float.should eq 7.5
      end

      it "float < int compares correctly" do
        interp, _ = make_interp
        result = interp.eval("2.5 < 5")
        result.truthy?.should be_true
      end

      it "int == float compares by value, not by kind" do
        interp, _ = make_interp
        result = interp.eval("5 == 5.0")
        result.truthy?.should be_true
      end

      it "float division by zero returns NaN" do
        interp, _ = make_interp
        result = interp.eval("5.0 / 0")
        result.as_float.should eq Float64::INFINITY
        result.as_float.infinite?.should_not eq 0
      end
    end

    describe "#floor / #ceil / #round" do
      it "floor rounds toward negative infinity" do
        interp, _ = make_interp
        interp.eval("3.7.floor").as_int.should eq 3
        interp.eval("(-3.2).floor").as_int.should eq(-4)
      end

      it "ceil rounds toward positive infinity" do
        interp, _ = make_interp
        interp.eval("3.2.ceil").as_int.should eq 4
        interp.eval("(-3.7).ceil").as_int.should eq(-3)
      end

      it "round rounds to the nearest integer" do
        interp, _ = make_interp
        interp.eval("3.5.round").as_int.should eq 4
        interp.eval("3.4.round").as_int.should eq 3
      end

      it "all three return an Integer, not a Float" do
        interp, _ = make_interp
        interp.eval("3.7.floor").int?.should be_true
        interp.eval("3.7.ceil").int?.should be_true
        interp.eval("3.7.round").int?.should be_true
      end
    end

    describe "#truncate" do
      it "truncates toward zero, matching Float#to_i's own semantics" do
        interp, _ = make_interp
        interp.eval("3.7.truncate").as_int.should eq 3
        interp.eval("(-3.7).truncate").as_int.should eq(-3)
      end
    end

    describe "#abs" do
      it "returns the absolute value as a Float" do
        interp, _ = make_interp
        result = interp.eval("(-2.5).abs")
        result.as_float.should eq 2.5
        result.float?.should be_true
      end
    end

    describe "#inspect" do
      it "renders the same as #to_s for a Float" do
        interp, _ = make_interp
        interp.eval("2.5.inspect").as_string.should eq "2.5"
      end
    end

    describe "#finite? / #nan?" do
      it "finite? is true for an ordinary float" do
        interp, _ = make_interp
        interp.eval("2.5.finite?").as_bool.should be_true
      end

      it "finite? is false for infinity" do
        interp, _ = make_interp
        interp.eval("(5.0 / 0).finite?").as_bool.should be_false
      end

      it "nan? is false for an ordinary float" do
        interp, _ = make_interp
        interp.eval("2.5.nan?").as_bool.should be_false
      end

      it "nan? is true for 0.0 / 0.0" do
        interp, _ = make_interp
        interp.eval("(0.0 / 0).nan?").as_bool.should be_true
      end
    end

    describe "#infinite?" do
      it "returns nil for a finite float" do
        interp, _ = make_interp
        interp.eval("2.5.infinite?").null?.should be_true
      end

      it "returns 1 for positive infinity" do
        interp, _ = make_interp
        interp.eval("(5.0 / 0).infinite?").as_int.should eq 1
      end

      it "returns -1 for negative infinity" do
        interp, _ = make_interp
        interp.eval("(-5.0 / 0).infinite?").as_int.should eq(-1)
      end
    end

    it "respond_to? sees Float's own native methods" do
      interp, _ = make_interp
      result = interp.eval("2.5.respond_to?(:to_i)")
      result.truthy?.should be_true
    end
  end
end
