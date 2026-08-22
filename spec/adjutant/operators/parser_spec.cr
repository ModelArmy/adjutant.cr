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

      it "parses =~ as a Binary node" do
        node = parse_expr("a =~ b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::EqTilde
      end

      it "parses a.=~(b) as an ordinary dot-call — no runtime equivalent yet, unlike a.===(b) before 2026-08-21" do
        # No special-casing needed in parse_postfix — EqTilde being a
        # single token (not separate Eq/Tilde) is the whole fix.
        # `a.===(b)` still parses the identical way (any single token's
        # lexeme works as a dot-call method name) but no longer
        # EVALUATES — `===` is a fixed opcode now (Op::TripleEq,
        # vm.cr), consulted only via bare infix `a === b` or
        # `case/when`, never through a receiver's method table; a
        # parsed `a.===(b)` Call node reaches the VM and raises
        # undefined-method (R008), same as `a.==(b)` always has. See
        # this describe block's own "===" tests below for the
        # PARSING side of that distinction.
        node = parse_expr("a.=~(b)")
        node.should be_a(Call)
        node.as(Call).method.should eq "=~"
      end

      it "respects precedence: =~ binds looser than +" do
        node = parse_expr("a =~ b + c")
        node.should be_a(Binary)
        top = node.as(Binary)
        top.op.should eq TokenKind::EqTilde
        top.right.should be_a(Binary)
        top.right.as(Binary).op.should eq TokenKind::Plus
      end

      it "parses !~ as a Binary node" do
        node = parse_expr("a !~ b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::BangTilde
      end

      it "parses a.!~(b) as an ordinary dot-call" do
        node = parse_expr("a.!~(b)")
        node.should be_a(Call)
        node.as(Call).method.should eq "!~"
      end

      it "parses a === b as a Binary node (added 2026-08-21)" do
        # Previously the one operator token deliberately excluded from
        # PRECEDENCE (see UNSUPPORTED.md's U017, pre-2026-08-21
        # wording) — `===` joined `==` as a second fixed-opcode
        # comparison instead of gaining ordinary receiver dispatch
        # (see DEVELOPMENT.md), so this now parses exactly like `==`
        # does, just a different token/opcode.
        node = parse_expr("a === b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::TripleEq
      end

      it "respects precedence: === binds looser than +, same tier as ==" do
        node = parse_expr("a === b + c")
        node.should be_a(Binary)
        top = node.as(Binary)
        top.op.should eq TokenKind::TripleEq
        top.right.should be_a(Binary)
        top.right.as(Binary).op.should eq TokenKind::Plus
      end

      it "parses a.===(b) as an ordinary dot-call at the PARSER level — see operators/vm_spec.cr for why this no longer evaluates" do
        # Parsing is unaffected by === becoming a fixed opcode: any
        # single token's lexeme still works as a dot-call method name
        # (parse_postfix, unchanged), so `a.===(b)` still produces an
        # ordinary Call node here. It's only the VM that now rejects
        # it (undefined method, same as `a.==(b)`) — a runtime
        # distinction, not a parser one, so this spec still passes.
        node = parse_expr("a.===(b)")
        node.should be_a(Call)
        node.as(Call).method.should eq "==="
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

      # Regression guard, added 2026-08-20 alongside `!~` itself
      # (SCOPE.md): `!~x` in PREFIX position (nothing to its left) is
      # real Ruby's double-unary `!(~x)`, NOT the infix negated-match
      # operator — before `!~` existed as one combined `BangTilde`
      # token, this parsed correctly for free (separate `Bang`+
      # `Tilde` tokens, composing via `parse_unary`'s own recursion).
      # `parse_unary`'s new `BangTilde` case rebuilds that same
      # composition explicitly — this test exists specifically to
      # catch it silently regressing back to a parse error if that
      # case is ever removed.
      it "parses !~x in prefix position as the double-unary !(~x), not negated-match" do
        node = parse_expr("!~x")
        node.should be_a(Unary)
        outer = node.as(Unary)
        outer.op.should eq TokenKind::Bang
        outer.expr.should be_a(Unary)
        inner = outer.expr.as(Unary)
        inner.op.should eq TokenKind::Tilde
        inner.expr.should be_a(Identifier)
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
