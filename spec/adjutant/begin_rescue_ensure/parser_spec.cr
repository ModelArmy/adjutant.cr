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

    describe "method-body (implicit) rescue/else/ensure" do
      # Real Ruby treats a `def` body as an implicit `begin` — no
      # `begin`/`end` wrapper needed to attach rescue/else/ensure.
      # Previously unsupported entirely (P002 at the `rescue` keyword
      # — see SCOPE.md's Must Fix entry, filed 2026-08-10, found while
      # testing `super` inside a rescue clause).
      it "wraps the body in a BeginNode when rescue is present" do
        src = "def foo\nrisky\nrescue Bar => e\nhandle\nend"
        node = parse_expr(src).as(DefNode)
        node.body.stmts.size.should eq 1
        wrapped = node.body.stmts.first.as(BeginNode)
        wrapped.rescue_clauses.size.should eq 1
        wrapped.rescue_clauses[0].var.should eq "e"
      end

      it "wraps the body when only ensure is present, no rescue at all" do
        src = "def foo\nrisky\nensure\ncleanup\nend"
        node = parse_expr(src).as(DefNode)
        wrapped = node.body.stmts.first.as(BeginNode)
        wrapped.rescue_clauses.should be_empty
        wrapped.ensure_body.should_not be_nil
      end

      it "does NOT wrap a plain def with no rescue/ensure at all" do
        src = "def foo\nx\ny\nend"
        node = parse_expr(src).as(DefNode)
        node.body.stmts.size.should eq 2
        node.body.stmts.any?(&.is_a?(BeginNode)).should be_false
      end

      it "supports multiple rescue clauses and an else, same as explicit begin" do
        src = "def foo\nrisky\nrescue TypeError\na\nrescue ArgumentError\nb\nelse\nc\nend"
        node = parse_expr(src).as(DefNode)
        wrapped = node.body.stmts.first.as(BeginNode)
        wrapped.rescue_clauses.size.should eq 2
        wrapped.else_body.should_not be_nil
      end

      it "rejects else with no rescue clause, same P004 real begin gets" do
        error = expect_raises(ParseError) do
          parse_expr("def foo\nrisky\nelse\nbar\nend")
        end
        error.diagnostic.not_nil!.code.should eq("P004")
      end

      it "def self.foo (a singleton method) supports implicit rescue too" do
        src = "def self.foo\nrisky\nrescue\nhandle\nend"
        node = parse_expr(src).as(DefNode)
        node.body.stmts.first.as(BeginNode).rescue_clauses.size.should eq 1
      end
    end
  end
end
