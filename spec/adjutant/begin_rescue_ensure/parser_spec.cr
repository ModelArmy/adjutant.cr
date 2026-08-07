require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "begin/rescue/ensure" do
      it "parses begin/rescue/ensure" do
        src = "begin\nfoo\nrescue e\nbar\nensure\nbaz\nend"
        node = parse_expr(src)
        node.should be_a(BeginNode)
        b = node.as(BeginNode)
        b.rescue_var.should eq "e"
        b.rescue_body.should_not be_nil
        b.ensure_body.should_not be_nil
      end

      it "parses rescue ClassName => var" do
        src = "begin\nfoo\nrescue TypeError => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_a(Constant)
        b.rescue_class.as(Constant).name.should eq "TypeError"
        b.rescue_var.should eq "e"
      end

      it "parses rescue ClassName with no bound variable" do
        src = "begin\nfoo\nrescue TypeError\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_a(Constant)
        b.rescue_var.should be_nil
      end

      it "parses rescue => var with no class filter" do
        src = "begin\nfoo\nrescue => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_nil
        b.rescue_var.should eq "e"
      end

      it "parses a qualified class path in rescue" do
        src = "begin\nfoo\nrescue Foo::Bar => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_a(ConstPath)
      end
    end
  end
end
