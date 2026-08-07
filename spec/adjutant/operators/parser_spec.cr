require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "binary expressions" do
      it "parses addition" do
        node = parse_expr("a + b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::Plus
      end

      it "parses comparison" do
        node = parse_expr("x == y")
        node.as(Binary).op.should eq TokenKind::EqEq
      end

      it "respects precedence: * before +" do
        node = parse_expr("a + b * c")
        node.should be_a(Binary)
        top = node.as(Binary)
        top.op.should eq TokenKind::Plus
        top.right.should be_a(Binary)
        top.right.as(Binary).op.should eq TokenKind::Star
      end

      it "parses logical and" do
        node = parse_expr("a && b")
        node.as(Binary).op.should eq TokenKind::AndAnd
      end

      it "parses logical or" do
        node = parse_expr("a || b")
        node.as(Binary).op.should eq TokenKind::OrOr
      end
    end

    describe "unary expressions" do
      it "parses negation" do
        node = parse_expr("-x")
        node.should be_a(Unary)
        node.as(Unary).op.should eq TokenKind::Minus
      end

      # Fixed 2026-07-25 (SCOPE.md's "Unary minus on a
      # NEGATIVE-NUMERIC-LITERAL binds looser than postfix" entry).
      # `-` immediately adjacent (no space) to a numeric literal fuses
      # into a single negative-literal node — NOT a Unary wrapping
      # anything — confirmed as the correct rule via a series of `irb`
      # experiments and Ruby's own parse.y grammar (tUMINUS_NUM),
      # distinct from the general "does unary minus bind tighter than
      # postfix" question, which it does NOT for anything other than
      # an immediately-adjacent literal.
      it "fuses minus with an immediately-adjacent integer literal (no Unary node)" do
        node = parse_expr("-7")
        node.should be_a(IntLiteral)
        node.as(IntLiteral).value.should eq "-7"
      end

      it "fuses minus with an immediately-adjacent float literal (no Unary node)" do
        node = parse_expr("-0.0")
        node.should be_a(FloatLiteral)
        node.as(FloatLiteral).value.should eq "-0.0"
      end

      it "applies postfix chaining to the FUSED literal, not to a Unary wrapping a postfix chain" do
        # This is the actual originally-reported bug shape:
        # `-0.0.to_s` must group as `(-0.0).to_s`, i.e. a Call whose
        # RECEIVER is the fused negative FloatLiteral — not a Unary
        # wrapping a Call on a positive 0.0.
        node = parse_expr("-0.0.to_s")
        node.should be_a(Call)
        call = node.as(Call)
        call.method.should eq "to_s"
        call.receiver.should be_a(FloatLiteral)
        call.receiver.as(FloatLiteral).value.should eq "-0.0"
      end

      it "does NOT fuse when there is a space between minus and the literal" do
        # `- 0.0.to_s` must still parse as the general Unary-wraps-
        # postfix form — `-(0.0.to_s)` — same as `-a.to_s` for a
        # variable. Confirmed empirically (irb): `- 0.0.to_s` groups
        # as unary-minus-of-the-call-result, NOT as a fused negative
        # literal, distinguishing this from the no-space case above by
        # whitespace alone (matching Ruby's own tUMINUS_NUM adjacency
        # rule, not a general precedence difference).
        node = parse_expr("- 0.0.to_s")
        node.should be_a(Unary)
        unary = node.as(Unary)
        unary.op.should eq TokenKind::Minus
        unary.expr.should be_a(Call)
      end

      it "does NOT fuse minus with a variable, even with no space" do
        # `-a.to_s` (a is a variable, not a literal) must remain
        # Unary(Minus, Call(...)) — negating the call's RESULT, per
        # Ruby's own documented behavior (bugs.ruby-lang.org/issues/
        # 19583) — regardless of adjacency, since fusion only ever
        # applies to a genuine numeric LITERAL token, never an
        # identifier.
        node = parse_expr("-a.to_s")
        node.should be_a(Unary)
        node.as(Unary).expr.should be_a(Call)
      end

      it "parses not" do
        node = parse_expr("!x")
        node.as(Unary).op.should eq TokenKind::Bang
      end

      # Fixed 2026-07-25 (SCOPE.md's "Unary + is entirely unsupported"
      # entry) — previously a parse error (`unexpected token Plus`)
      # since parse_unary had no TokenKind::Plus case at all.
      it "parses unary plus" do
        node = parse_expr("+x")
        node.should be_a(Unary)
        node.as(Unary).op.should eq TokenKind::Plus
      end
    end

    describe "ternary" do
      it "parses ternary expression" do
        node = parse_expr("a ? b : c")
        node.should be_a(Ternary)
      end
    end
  end
end
