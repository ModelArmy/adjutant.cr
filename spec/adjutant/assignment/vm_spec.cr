require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "variables" do
      it "assigns and reads a variable" do
        eval("x = 42\nx").as_int.should eq 42_i64
      end

      it "reassigns a variable" do
        eval("x = 1\nx = 2\nx").as_int.should eq 2_i64
      end

      it "evaluates compound assignment +=" do
        eval("x = 10\nx += 5\nx").as_int.should eq 15_i64
      end

      it "evaluates ||= when nil" do
        eval("x = nil\nx ||= 42\nx").as_int.should eq 42_i64
      end

      it "evaluates ||= when already set" do
        eval("x = 1\nx ||= 99\nx").as_int.should eq 1_i64
      end
    end

    describe "multi-target assignment" do
      it "assigns from a literal comma list" do
        eval("a, b = 1, 2\n[a, b]").as_array[0].as_int.should eq 1_i64
        eval("a, b = 1, 2\n[a, b]").as_array[1].as_int.should eq 2_i64
      end

      it "swaps two variables with no temp" do
        eval("a = 1\nb = 2\na, b = b, a\na").as_int.should eq 2_i64
        eval("a = 1\nb = 2\na, b = b, a\nb").as_int.should eq 1_i64
      end

      it "splats a single Array-valued rhs across targets" do
        result = eval("a, b = [1, 2]\n[a, b]").as_array
        result[0].as_int.should eq 1_i64
        result[1].as_int.should eq 2_i64
      end

      it "splats an array from a variable, not just a literal" do
        result = eval("xs = [10, 20]\na, b = xs\n[a, b]").as_array
        result[0].as_int.should eq 10_i64
        result[1].as_int.should eq 20_i64
      end

      it "pads with nil when there are more targets than values" do
        result = eval("a, b, c = 1, 2\n[a, b, c]").as_array
        result[2].null?.should be_true
      end

      it "truncates extra values when there are more values than targets" do
        result = eval("a, b = 1, 2, 3\n[a, b]").as_array
        result[0].as_int.should eq 1_i64
        result[1].as_int.should eq 2_i64
      end

      it "does not splat a non-array single value" do
        result = eval("a, b = 5\n[a, b]").as_array
        result[0].as_int.should eq 5_i64
        result[1].null?.should be_true
      end

      it "does not splat when a literal array is only one of several rhs values" do
        # a, b = [1, 2], 3 — two rhs values at the top level, so no
        # runtime splat applies; a gets the array itself, b gets 3.
        result = eval("a, b = [1, 2], 3\n[a, b]").as_array
        result[0].as_array[0].as_int.should eq 1_i64
        result[0].as_array[1].as_int.should eq 2_i64
        result[1].as_int.should eq 3_i64
      end
    end
  end
end
