require "../spec_helper"

# Investigation spec for the missing-skip_newlines shape found while
# fixing the bare-call comma bug (HANDOFF-2026-08-18.md / SCOPE.md).
# `parse_bare_call_args`'s comma loop was missing a `skip_newlines`
# call the parenthesized call-arg path already had; this file checks
# every OTHER comma loop in the parser for the identical gap, plus the
# separately-flagged binary-operator loop. One spec per site, so it's
# obvious from a single run which sites are already fine and which
# still need the fix — see HANDOFF's follow-up for results.
module Adjutant
  describe Parser do
    describe "newline continuation after a trailing comma (or operator)" do
      # --- paren/pipe-delimited: unambiguous, parens already signal
      #     "keep going" regardless of what real Ruby allows bare ---

      it "parses yield(...) args split across a newline after the comma" do
        node = parse_expr("def f\n  yield(1,\n    2)\nend").as(DefNode)
        y = node.body.stmts.first.as(YieldNode)
        y.args.size.should eq 2
      end

      it "parses super(...) args split across a newline after the comma" do
        node = parse_expr("class C\n  def f\n    super(1,\n      2)\n  end\nend").as(ClassNode)
        f = node.body.stmts.first.as(DefNode)
        s = f.body.stmts.first.as(SuperNode)
        s.args.size.should eq 2
      end

      it "parses a def's parameter list split across a newline after the comma" do
        node = parse_expr("def f(a,\n  b)\n  a\nend").as(DefNode)
        node.params.size.should eq 2
      end

      it "parses a block's parameter list split across a newline after the comma" do
        node = parse_expr("[1].each { |a,\n  b| a }")
        call = node.as(Call)
        call.block.not_nil!.params.size.should eq 2
      end

      # --- bare (no-paren): same general principle (a trailing comma
      #     can't end a statement), applied per construct ---

      it "parses bare super args split across a newline after the comma" do
        node = parse_expr("class C\n  def f(a, b)\n    super a,\n      b\n  end\nend").as(ClassNode)
        f = node.body.stmts.first.as(DefNode)
        s = f.body.stmts.first.as(SuperNode)
        s.args.size.should eq 2
      end

      it "parses bare raise args split across a newline after the comma" do
        node = parse_expr("raise ArgumentError,\n  \"boom\"")
        node.should be_a(Call)
        node.as(Call).args.size.should eq 2
      end

      it "parses multi-assign targets split across a newline after the comma" do
        node = parse_expr("a,\n  b = 1, 2")
        node.should be_a(MultiAssign)
        node.as(MultiAssign).targets.size.should eq 2
      end

      it "parses multi-rhs values split across a newline after the comma" do
        node = parse_expr("x, y = 1,\n  2")
        node.should be_a(MultiAssign)
        node.as(MultiAssign).values.size.should eq 2
      end

      it "parses for-loop variables split across a newline after the comma" do
        node = parse_expr("for a,\n    b in [[1, 2]]\n  a\nend")
        node.should be_a(ForNode)
        node.as(ForNode).vars.size.should eq 2
      end

      it "parses case/when patterns split across a newline after the comma" do
        node = parse_expr("case 1\nwhen 1,\n     2\n  :low\nend")
        node.should be_a(CaseNode)
        node.as(CaseNode).whens.first[0].size.should eq 2
      end

      it "parses rescue with multiple classes split across a newline after the comma" do
        node = parse_expr("begin\n  x\nrescue ArgumentError,\n       TypeError => e\n  y\nend")
        node.should be_a(BeginNode)
        node.as(BeginNode).rescue_clauses.first.classes.size.should eq 2
      end

      # --- separately-flagged, related gap: the main binary-operator
      #     loop in parse_expression itself, not a comma loop at all ---

      it "parses a binary expression split across a newline after the operator" do
        node = parse_expr("1 +\n  2")
        node.should be_a(Binary)
      end

      it "parses a logical-and expression split across a newline after the operator" do
        node = parse_expr("true &&\n  false")
        node.should be_a(Binary)
      end
    end
  end
end
