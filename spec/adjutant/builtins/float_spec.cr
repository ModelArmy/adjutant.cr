require "../../spec_helper"

module Adjutant
  # Covers Phase 3 of the base-types work: Float. Mirrors Integer's
  # existing coverage closely — arithmetic/comparison are opcodes, not
  # methods, and already handle Integer/Float mixing (see vm_spec.cr
  # for those); this file covers Float's own RubyClass (.class,
  # is_a?, superclass) and its three native methods (to_s, to_i,
  # to_f).
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

      it "float division by zero raises, same as integer division by zero" do
        interp, _ = make_interp
        expect_raises(RuntimeError, /divided by 0/) do
          interp.eval("5.0 / 0")
        end
      end
    end

    it "respond_to? sees Float's own native methods" do
      interp, _ = make_interp
      result = interp.eval("2.5.respond_to?(:to_i)")
      result.truthy?.should be_true
    end
  end
end
