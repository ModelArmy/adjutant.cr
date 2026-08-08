require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "begin/rescue/ensure" do
      it "parses begin/rescue/ensure" do
        src = "begin\nfoo\nrescue e\nbar\nensure\nbaz\nend"
        node = parse_expr(src)
        node.should be_a(BeginNode)
        b = node.as(BeginNode)
        b.rescue_clauses.size.should eq 1
        b.rescue_clauses[0].var.should eq "e"
        b.rescue_clauses[0].classes.should be_empty
        b.ensure_body.should_not be_nil
      end

      it "parses rescue ClassName => var" do
        src = "begin\nfoo\nrescue TypeError => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        clause = b.rescue_clauses[0]
        clause.classes.size.should eq 1
        clause.classes[0].should be_a(Constant)
        clause.classes[0].as(Constant).name.should eq "TypeError"
        clause.var.should eq "e"
      end

      it "parses rescue ClassName with no bound variable" do
        src = "begin\nfoo\nrescue TypeError\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        clause = b.rescue_clauses[0]
        clause.classes[0].should be_a(Constant)
        clause.var.should be_nil
      end

      it "parses rescue => var with no class filter" do
        src = "begin\nfoo\nrescue => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        clause = b.rescue_clauses[0]
        clause.classes.should be_empty
        clause.var.should eq "e"
      end

      it "parses a qualified class path in rescue" do
        src = "begin\nfoo\nrescue Foo::Bar => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_clauses[0].classes[0].should be_a(ConstPath)
      end

      it "parses rescue A, B => var (multiple types, one clause)" do
        src = "begin\nfoo\nrescue TypeError, ArgumentError => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_clauses.size.should eq 1
        clause = b.rescue_clauses[0]
        clause.classes.size.should eq 2
        clause.classes[0].as(Constant).name.should eq "TypeError"
        clause.classes[1].as(Constant).name.should eq "ArgumentError"
        clause.var.should eq "e"
      end

      it "parses multiple rescue clauses on one begin" do
        src = "begin\nfoo\nrescue TypeError => e\nbar\nrescue ArgumentError\nbaz\nrescue\nqux\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_clauses.size.should eq 3
        b.rescue_clauses[0].classes[0].as(Constant).name.should eq "TypeError"
        b.rescue_clauses[0].var.should eq "e"
        b.rescue_clauses[1].classes[0].as(Constant).name.should eq "ArgumentError"
        b.rescue_clauses[1].var.should be_nil
        b.rescue_clauses[2].classes.should be_empty
        b.rescue_clauses[2].var.should be_nil
      end

      it "parses begin/rescue/else" do
        src = "begin\nfoo\nrescue\nbar\nelse\nbaz\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_clauses.size.should eq 1
        b.else_body.should_not be_nil
      end

      it "parses begin/rescue/else/ensure together" do
        src = "begin\nfoo\nrescue\nbar\nelse\nbaz\nensure\nqux\nend"
        b = parse_expr(src).as(BeginNode)
        b.else_body.should_not be_nil
        b.ensure_body.should_not be_nil
      end

      it "rejects else with no rescue clause at all (P004, matches real " \
         "Ruby's SyntaxError — confirmed against irb)" do
        error = expect_raises(ParseError) do
          parse_expr("begin\nfoo\nelse\nbar\nend")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("P004")
      end

      it "rejects a second else clause (P005, matches real Ruby's " \
         "SyntaxError — confirmed against irb)" do
        error = expect_raises(ParseError) do
          parse_expr("begin\nfoo\nrescue\nbar\nelse\nbaz\nelse\nqux\nend")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("P005")
      end
    end
  end
end
