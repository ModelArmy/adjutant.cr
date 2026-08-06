require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "literals" do
      it "parses nil" do
        parse_expr("nil").should be_a(NilLiteral)
      end

      it "parses true" do
        node = parse_expr("true")
        node.should be_a(BoolLiteral)
        node.as(BoolLiteral).value.should be_true
      end

      it "parses false" do
        node = parse_expr("false")
        node.as(BoolLiteral).value.should be_false
      end

      it "parses an integer" do
        node = parse_expr("42")
        node.should be_a(IntLiteral)
        node.as(IntLiteral).value.should eq "42"
      end

      it "parses a float" do
        node = parse_expr("3.14")
        node.should be_a(FloatLiteral)
        node.as(FloatLiteral).value.should eq "3.14"
      end

      it "parses a string literal" do
        node = parse_expr(%("hello"))
        node.should be_a(StringLiteral)
        node.as(StringLiteral).value.should eq "hello"
      end

      it "parses a symbol" do
        node = parse_expr(":ok")
        node.should be_a(SymbolLiteral)
        node.as(SymbolLiteral).value.should eq "ok"
      end

      it "parses an array literal" do
        node = parse_expr("[1, 2, 3]")
        node.should be_a(ArrayLiteral)
        node.as(ArrayLiteral).elements.size.should eq 3
      end

      it "parses an empty array" do
        node = parse_expr("[]")
        node.as(ArrayLiteral).elements.should be_empty
      end

      it "parses a hash literal" do
        node = parse_expr(%({ "a" => 1 }))
        node.should be_a(HashLiteral)
        node.as(HashLiteral).pairs.size.should eq 1
      end

      it "parses an inclusive range" do
        node = parse_expr("1..10")
        node.should be_a(RangeLiteral)
        node.as(RangeLiteral).exclusive?.should be_false
      end

      it "parses an exclusive range" do
        node = parse_expr("1...10")
        node.as(RangeLiteral).exclusive?.should be_true
      end

      it "parses an interpolated string" do
        node = parse_expr("\"hello \#{name}!\"")
        node.should be_a(InterpString)
        parts = node.as(InterpString).parts
        parts.size.should eq 3
        parts[0].should be_a(StringFragment)
        parts[0].as(StringFragment).value.should eq "hello "
        parts[1].should be_a(Identifier)
        parts[2].should be_a(StringFragment)
        parts[2].as(StringFragment).value.should eq "!"
      end
    end

    describe "variables" do
      it "parses an identifier" do
        node = parse_expr("foo")
        node.should be_a(Identifier)
        node.as(Identifier).name.should eq "foo"
      end

      it "parses a constant" do
        node = parse_expr("MyClass")
        node.should be_a(Constant)
        node.as(Constant).name.should eq "MyClass"
      end

      it "parses an instance variable" do
        node = parse_expr("@name")
        node.should be_a(IVar)
        node.as(IVar).name.should eq "@name"
      end

      it "parses a class variable" do
        node = parse_expr("@@count")
        node.should be_a(CVar)
        node.as(CVar).name.should eq "@@count"
      end

      it "parses self" do
        parse_expr("self").should be_a(SelfNode)
      end
    end
  end
end
