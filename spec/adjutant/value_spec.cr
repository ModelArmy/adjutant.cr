require "../spec_helper"

module Adjutant
  describe Value do
    describe "nil value" do
      it "has Nil tag" do
        Value.nil_value.tag.should eq ValueTag::Nil
      end

      it "is null?" do
        Value.nil_value.null?.should be_true
      end

      it "is falsy" do
        Value.nil_value.truthy?.should be_false
      end

      it "renders as nil" do
        Value.nil_value.to_s.should eq "nil"
      end
    end

    describe "bool values" do
      it "stores true" do
        v = Value.bool(true)
        v.tag.should eq ValueTag::Bool
        v.as_bool.should be_true
        v.truthy?.should be_true
      end

      it "stores false" do
        v = Value.bool(false)
        v.as_bool.should be_false
        v.truthy?.should be_false
      end

      it "renders correctly" do
        Value.bool(true).to_s.should eq "true"
        Value.bool(false).to_s.should eq "false"
      end
    end

    describe "int values" do
      it "stores an integer" do
        v = Value.int(42_i64)
        v.tag.should eq ValueTag::Int
        v.as_int.should eq 42_i64
        v.truthy?.should be_true
      end

      it "stores negative integers" do
        Value.int(-7_i64).as_int.should eq -7_i64
      end

      it "renders correctly" do
        Value.int(99_i64).to_s.should eq "99"
      end
    end

    describe "float values" do
      it "stores a float" do
        v = Value.float(3.14)
        v.tag.should eq ValueTag::Float
        v.as_float.should be_close(3.14, 1e-10)
        v.truthy?.should be_true
      end

      it "renders correctly" do
        Value.float(1.5).to_s.should eq "1.5"
      end
    end

    describe "string values" do
      it "stores a string" do
        v = Value.string("hello")
        v.tag.should eq ValueTag::String
        v.as_string.should eq "hello"
        v.truthy?.should be_true
      end

      it "renders without quotes via to_s" do
        Value.string("hello").to_s.should eq "hello"
      end

      it "renders with quotes via inspect" do
        Value.string("hello").inspect.should eq "\"hello\""
      end
    end

    describe "symbol values" do
      it "stores a symbol" do
        v = Value.symbol("ok")
        v.tag.should eq ValueTag::Symbol
        v.as_symbol.should eq "ok"
        v.truthy?.should be_true
      end

      it "renders with colon prefix" do
        Value.symbol("name").to_s.should eq ":name"
      end

      it "renders with colon prefix via inspect" do
        Value.symbol("name").inspect.should eq ":name"
      end
    end

    describe "IFC label handling" do
      it "has no label by default" do
        Value.int(1_i64).label.should be_nil
      end

      it "carries a label when constructed with one" do
        l = SecurityLabel.new("network")
        v = Value.int(1_i64, l)
        v.label.should eq l
      end

      it "attaches a label via with_label" do
        l = SecurityLabel.new("fs")
        v = Value.int(1_i64).with_label(l)
        v.label.should eq l
        v.as_int.should eq 1_i64
      end

      it "label propagates on copy (struct assignment)" do
        l = SecurityLabel.new("user_input")
        a = Value.int(42_i64, l)
        b = a # struct copy
        b.label.should eq l
        b.as_int.should eq 42_i64
      end

      it "joins labels from two values" do
        la = SecurityLabel.new("network")
        lb = SecurityLabel.new("fs")
        a = Value.int(1_i64, la)
        b = Value.int(2_i64, lb)
        result = a.join_label(b)
        result.label.should_not be_nil
        result.label.not_nil!.name.should eq "network+fs"
      end

      it "shows label in inspect output" do
        l = SecurityLabel.new("network")
        v = Value.string("secret", l)
        v.inspect.should eq "\"secret\" [label:network]"
      end
    end
  end
end
