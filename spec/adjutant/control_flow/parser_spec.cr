require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "control flow" do
      it "parses an if statement" do
        node = parse_expr("if x\ny\nend")
        node.should be_a(IfNode)
      end

      it "parses if/elsif/else" do
        node = parse_expr("if a\n1\nelsif b\n2\nelse\n3\nend")
        n = node.as(IfNode)
        n.elsif_branches.size.should eq 1
        n.else_branch.should_not be_nil
      end

      it "parses unless" do
        node = parse_expr("unless x\ny\nend")
        node.should be_a(UnlessNode)
      end

      it "parses a while loop" do
        node = parse_expr("while x > 0\nx -= 1\nend")
        node.should be_a(WhileNode)
        node.as(WhileNode).until_loop?.should be_false
      end

      it "parses an until loop" do
        node = parse_expr("until x == 0\nx -= 1\nend")
        node.as(WhileNode).until_loop?.should be_true
      end

      it "parses a while loop with a trailing do" do
        node = parse_expr("while x > 0 do\nx -= 1\nend")
        node.should be_a(WhileNode)
      end

      it "parses an until loop with a trailing do" do
        node = parse_expr("until x == 0 do\nx -= 1\nend")
        node.should be_a(WhileNode)
        node.as(WhileNode).until_loop?.should be_true
      end

      it "parses a while loop whose condition ends in a bare identifier, with do" do
        # Regression: `running do` used to parse as a parenless
        # call-with-block on `running`, swallowing the while-loop's
        # own `end`.
        node = parse_expr("while running do\nstep\nend")
        node.should be_a(WhileNode)
      end

      it "parses a while loop whose condition ends in a dot-call, with do" do
        # Regression: the same ambiguity applies to a parenless
        # dot-call as the rightmost primary before `do` (`a.size do`),
        # not just a bare identifier — block_follows_no_paren? is
        # checked from parse_call_args_and_block too.
        node = parse_expr("while i < a.size do\ni += 1\nend")
        node.should be_a(WhileNode)
      end

      it "parses a for loop" do
        node = parse_expr("for i in 1..3\nputs(i)\nend")
        node.should be_a(ForNode)
        node.as(ForNode).vars.should eq ["i"]
      end

      it "parses a for loop over a bare-identifier iterable with a trailing do" do
        # Regression: `a do` used to parse as a parenless call-with-
        # block on `a`, swallowing the for-loop's own `end` and
        # leaving the parser expecting KwEnd at EOF.
        node = parse_expr("for o in a do\nputs(o)\nend")
        node.should be_a(ForNode)
        node.as(ForNode).vars.should eq ["o"]
        node.as(ForNode).iter.should be_a(Identifier)
      end

      it "parses a for loop over a bare-identifier iterable without do" do
        node = parse_expr("for o in a\nputs(o)\nend")
        node.should be_a(ForNode)
        node.as(ForNode).iter.should be_a(Identifier)
      end

      it "still parses a normal parenless call-with-block outside a for-loop" do
        # Confirms the no_do_block suppression is properly scoped to
        # the for-loop's iterable and doesn't leak into unrelated
        # parsing.
        node = parse_expr("foo do\n1\nend")
        node.should be_a(Call)
        node.as(Call).block.should_not be_nil
      end

      it "parses a case statement" do
        node = parse_expr("case x\nwhen 1\n:one\nwhen 2\n:two\nend")
        node.should be_a(CaseNode)
        node.as(CaseNode).whens.size.should eq 2
      end

      it "parses return" do
        node = parse_expr("return 42")
        node.should be_a(ReturnNode)
        node.as(ReturnNode).value.should be_a(IntLiteral)
      end

      it "parses bare return" do
        node = parse_expr("return")
        node.as(ReturnNode).value.should be_nil
      end

      it "parses break" do
        parse_expr("break").should be_a(BreakNode)
      end

      it "parses next" do
        parse_expr("next").should be_a(NextNode)
      end

      it "parses modifier if" do
        node = parse_expr("puts(x) if x")
        node.should be_a(ModifierIf)
        node.as(ModifierIf).negated?.should be_false
      end

      it "parses modifier unless" do
        node = parse_expr("puts(x) unless x.null?")
        node.should be_a(ModifierIf)
        node.as(ModifierIf).negated?.should be_true
      end

      it "parses modifier while" do
        node = parse_expr("x -= 1 while x > 0")
        node.should be_a(ModifierWhile)
      end

      it "rejects a bare begin...end while (do-while) statement with U016" do
        # Regression coverage for a bug found 2026-08-06: parse_statement's
        # `KwBegin` case called parse_begin directly and returned its
        # bare BeginNode immediately, with no check for a trailing
        # `while`/`until` — the modifier was left dangling as what
        # looked like the start of an unrelated next statement, which
        # the parser then reported as a confusing, unrelated P003
        # ("`while` is missing its `end`") with no hint that
        # begin/rescue/ensure had anything to do with it. do-while is
        # a deliberate exclusion (UNSUPPORTED.md, U016), not merely
        # unimplemented — this confirms the BARE-statement form
        # (no assignment) is rejected with a clear, purpose-built
        # error instead of that confusing fallback.
        error = expect_raises(ParseError) do
          Parser.new("begin\n  1\nend while true\n", "t.rb").parse
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("U016")
        diag.primary.not_nil!.line.should eq(1)
      end

      it "rejects a bare begin...end until (do-while) statement with U016" do
        error = expect_raises(ParseError) do
          Parser.new("begin\n  1\nend until false\n", "t.rb").parse
        end
        error.diagnostic.not_nil!.code.should eq("U016")
      end

      it "does not reject an ordinary begin...end with no trailing " \
         "while/until modifier" do
        # Regression guard for the checks above — an ordinary begin/end
        # with nothing following it must be completely unaffected.
        node = parse_expr("begin\n  1\nend")
        node.should be_a(BeginNode)
      end

      it "does not reject begin...end followed by an unrelated next " \
         "statement" do
        # Guards against over-matching on mere token adjacency rather
        # than the specific KwWhile/KwUntil check — an ordinary
        # begin/end followed by a completely separate statement on the
        # next line must parse as two statements, not trigger U016.
        body = parse("begin\n  1\nend\nx = 2\n")
        body.stmts.size.should eq(2)
        body.stmts.first.should be_a(BeginNode)
      end
    end

    describe "expression-position control flow" do
      it "parses if as assignment rhs" do
        node = parse_expr("x = if a\n1\nelse\n2\nend")
        assign = node.as(Assign)
        assign.value.should be_a(IfNode)
      end

      it "parses if/elsif/else as assignment rhs" do
        node = parse_expr("x = if a\n1\nelsif b\n2\nelse\n3\nend")
        n = node.as(Assign).value.as(IfNode)
        n.elsif_branches.size.should eq 1
      end

      it "parses if result compared in a binary expression" do
        node = parse_expr("(if a\n1\nelse\n2\nend) == x")
        bin = node.as(Binary)
        bin.left.should be_a(IfNode)
      end

      it "parses unless as assignment rhs" do
        node = parse_expr("x = unless a\n1\nelse\n2\nend")
        node.as(Assign).value.should be_a(UnlessNode)
      end

      it "parses case as assignment rhs" do
        node = parse_expr("x = case y\nwhen 1\n:one\nelse\n:other\nend")
        n = node.as(Assign).value.as(CaseNode)
        n.whens.size.should eq 1
      end

      it "parses begin/rescue as assignment rhs" do
        node = parse_expr("x = begin\nfoo\nrescue e\nbar\nend")
        n = node.as(Assign).value.as(BeginNode)
        n.rescue_clauses[0].var.should eq "e"
      end

      it "parses if as a call argument" do
        node = parse_expr("puts(if a\n1\nelse\n2\nend)")
        call = node.as(Call)
        call.args.first.should be_a(IfNode)
      end

      it "statement-position if is unaffected" do
        node = parse_expr("if x\ny\nend")
        node.should be_a(IfNode)
      end
    end
  end
end
