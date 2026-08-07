require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "literals" do
      it "evaluates nil" do
        eval("nil").null?.should be_true
      end

      it "evaluates true" do
        eval("true").as_bool.should be_true
      end

      it "evaluates false" do
        eval("false").as_bool.should be_false
      end

      it "evaluates an integer" do
        eval("42").as_int.should eq 42_i64
      end

      it "evaluates a float" do
        eval("3.14").as_float.should be_close(3.14, 1e-10)
      end

      it "evaluates a string" do
        eval(%("hello")).as_string.should eq "hello"
      end

      it "evaluates a symbol" do
        v = eval(":ok")
        v.symbol?.should be_true
        v.as_sym.name.should eq "ok"
      end

      it "evaluates an array literal" do
        v = eval("[1, 2, 3]")
        v.array?.should be_true
        v.as_array.size.should eq 3
      end

      it "evaluates a hash literal" do
        v = eval(%({ "a" => 1 }))
        v.hash?.should be_true
        v.as_hash.size.should eq 1
      end
    end

    describe "string interpolation" do
      it "interpolates an integer" do
        eval(%("value: \#{42}")).as_string.should eq "value: 42"
      end

      it "interpolates a variable" do
        eval(%(x = "world"\n"hello \#{x}")).as_string.should eq "hello world"
      end
    end
  end
end
