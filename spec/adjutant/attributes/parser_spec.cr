require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "attr_reader / attr_writer / attr_accessor" do
      it "desugars attr_reader :x into a single arg-less getter DefNode" do
        node = parse_expr("attr_reader :x")
        node.should be_a(DefNode)
        d = node.as(DefNode)
        d.name.should eq "x"
        d.params.should be_empty
        d.body.stmts.size.should eq 1
        d.body.stmts.first.should be_a(IVar)
        d.body.stmts.first.as(IVar).name.should eq "@x"
      end

      it "desugars attr_writer :x into a def x=(value) DefNode assigning the ivar" do
        node = parse_expr("attr_writer :x")
        node.should be_a(DefNode)
        d = node.as(DefNode)
        d.name.should eq "x="
        d.params.size.should eq 1
        d.params.first.name.should eq "value"
        d.params.first.kwarg?.should be_false
        d.params.first.splat?.should be_false
        d.body.stmts.size.should eq 1
        assign = d.body.stmts.first.as(Assign)
        assign.target.as(IVar).name.should eq "@x"
        assign.value.as(Identifier).name.should eq "value"
      end

      it "desugars attr_accessor :x into both a getter and a setter" do
        # A single name still yields TWO real top-level statements —
        # this is the shape append_statement's flattening exists for
        # (see that method's own comment, parser.cr). Asserted via
        # `parse` (the whole top-level Body), not `parse_expr` (which
        # only returns the first statement) — parse_expr alone
        # couldn't tell a correctly-flattened two-statement result
        # apart from an incorrectly-nested one-statement result.
        body = parse("attr_accessor :x")
        body.stmts.size.should eq 2
        body.stmts[0].should be_a(DefNode)
        body.stmts[1].should be_a(DefNode)
        body.stmts[0].as(DefNode).name.should eq "x"
        body.stmts[1].as(DefNode).name.should eq "x="
      end

      it "desugars attr_accessor :x, :y into four flat DefNodes, x/x=/y/y= in order" do
        body = parse("attr_accessor :x, :y")
        body.stmts.map { |s| s.as(DefNode).name }.should eq(["x", "x=", "y", "y="])
      end

      it "accepts optional parens, same as a real method call" do
        node = parse_expr("attr_reader(:x)")
        node.should be_a(DefNode)
        node.as(DefNode).name.should eq "x"
      end

      # The trailing-comma-newline sweep of 2026-08-18 missed this
      # site (see SCOPE.md's Will Fix note) — same shape as every
      # other comma loop that got the fix, both the parenthesized and
      # bare forms. Confirmed against real Ruby first (both split
      # fine) before fixing.
      it "parses attr_accessor names split across a newline after the comma, parens" do
        body = parse("attr_accessor :x,\n  :y")
        body.stmts.map { |s| s.as(DefNode).name }.should eq(["x", "x=", "y", "y="])
      end

      it "parses attr_reader names split across a newline after the comma, bare" do
        body = parse("attr_reader :x,\n  :y")
        body.stmts.map { |s| s.as(DefNode).name }.should eq(["x", "y"])
      end

      # The critical regression: parse_attr returns a `Body` wrapping
      # its synthetic DefNodes (see that method's own comment), and
      # every statement-list builder (`parse`, `parse_body_until`,
      # `parse_body_until_any`) MUST flatten it via `append_statement`
      # rather than nesting it as a single child — RiskWalker#walk_class
      # specifically pattern-matches `stmt.is_a?(DefNode)` on each of a
      # class body's DIRECT statements (see risk_walker_spec.cr for the
      # RiskWalker-level regression covering the actual consequence).
      it "flattens attr_accessor's synthetic defs directly into an enclosing class body" do
        node = parse_expr(<<-RUBY)
          class Point
            attr_accessor :x, :y
            def initialize(x, y)
              @x = x
              @y = y
            end
          end
          RUBY
        cls = node.as(ClassNode)
        # 4 attr defs + 1 initialize def = 5 flat statements, none of
        # them a nested Body.
        cls.body.stmts.size.should eq 5
        cls.body.stmts.each { |s| s.should be_a(DefNode) }
        cls.body.stmts.map { |s| s.as(DefNode).name }.should eq(
          ["x", "x=", "y", "y=", "initialize"]
        )
      end

      it "flattens the same way inside a module body" do
        node = parse_expr(<<-RUBY)
          module M
            attr_accessor :x
          end
          RUBY
        mod = node.as(ModuleNode)
        mod.body.stmts.size.should eq 2
        mod.body.stmts.each { |s| s.should be_a(DefNode) }
      end

      it "flattens correctly even at the very top level (no enclosing class)" do
        body = parse("attr_accessor :x\nputs 1")
        body.stmts.size.should eq 3
        body.stmts[0].should be_a(DefNode)
        body.stmts[1].should be_a(DefNode)
        body.stmts[2].should be_a(Call)
      end
    end
  end
end
