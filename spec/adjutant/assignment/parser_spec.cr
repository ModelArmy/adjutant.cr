require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "assignment" do
      it "parses simple assignment" do
        node = parse_expr("x = 1")
        node.should be_a(Assign)
        node.as(Assign).target.as(Identifier).name.should eq "x"
        node.as(Assign).value.as(IntLiteral).value.should eq "1"
      end

      it "parses += compound assignment" do
        node = parse_expr("x += 1")
        node.should be_a(OpAssign)
        node.as(OpAssign).op.should eq TokenKind::Plus
      end

      it "parses ||= conditional assignment" do
        node = parse_expr("x ||= nil")
        node.should be_a(CondAssign)
        node.as(CondAssign).op.should eq TokenKind::OrAssign
      end
    end

    describe "assignment as a real expression (not statement-only)" do
      # SCOPE.md's "Assignment isn't a real expression" entry, both
      # manifestations: assignment was previously only ever built at
      # the statement level (`maybe_assignment`, called once from
      # `parse_expr_statement`), so anything parsed via the general
      # `parse_expression` chain — a parenthesized group, chained `=`,
      # a call/index argument, ... — structurally couldn't contain one.
      # Fixed by checking for `=`/compound-assign immediately after
      # `parse_expression` parses its primary (`left = parse_unary`),
      # before its own binary-operator loop runs — not gated on
      # `min_prec` (see `parse_expression`'s own comment for why: an
      # identifier immediately followed by `=` commits to being an
      # assignment target the instant it's parsed, regardless of the
      # enclosing operator's precedence level, matching real Ruby).

      it "parses chained assignment (c = b = 5), right-associatively" do
        node = parse_expr("c = b = 5").as(Assign)
        node.target.as(Identifier).name.should eq "c"
        inner = node.value.as(Assign)
        inner.target.as(Identifier).name.should eq "b"
        inner.value.as(IntLiteral).value.should eq "5"
      end

      it "parses a three-deep assignment chain (a = b = c = 1)" do
        node = parse_expr("a = b = c = 1").as(Assign)
        node.target.as(Identifier).name.should eq "a"
        mid = node.value.as(Assign)
        mid.target.as(Identifier).name.should eq "b"
        inner = mid.value.as(Assign)
        inner.target.as(Identifier).name.should eq "c"
        inner.value.as(IntLiteral).value.should eq "1"
      end

      it "parses a parenthesized nested assignment (x = (w.attr = 5))" do
        node = parse_expr("x = (w.attr = 5)").as(Assign)
        node.target.as(Identifier).name.should eq "x"
        inner = node.value.as(AttrAssign)
        inner.method.should eq "attr"
        inner.value.as(IntLiteral).value.should eq "5"
      end

      it "parses a parenthesized nested assignment with a plain lvalue (x = (y = 5))" do
        node = parse_expr("x = (y = 5)").as(Assign)
        inner = node.value.as(Assign)
        inner.target.as(Identifier).name.should eq "y"
        inner.value.as(IntLiteral).value.should eq "5"
      end

      it "parses assignment as a call argument (f(x = 1))" do
        node = parse_expr("f(x = 1)").as(Call)
        node.args.first.should be_a(Assign)
      end

      it "parses assignment as an array literal element ([x = 1, 2])" do
        node = parse_expr("[x = 1, 2]").as(ArrayLiteral)
        node.elements.first.should be_a(Assign)
      end

      it "parses compound assignment nested in parens (x += (y = 1))" do
        node = parse_expr("x += (y = 1)").as(OpAssign)
        node.value.should be_a(Assign)
      end

      it "an identifier immediately followed by = commits to assignment even as an operator's own right-hand side (7 == tot = 1)" do
        # Confirmed against real Ruby (docs.ruby-lang.org's own
        # precedence table lists `=` BELOW `==`, which reads as
        # "binds looser" — but that's not how the grammar actually
        # resolves this shape): assignment is recognized locally, the
        # moment a bare lvalue is parsed and immediately followed by
        # `=`, regardless of the enclosing operator's own precedence
        # level — not deferred until that operator's own combining
        # step has already run. `7 == tot = 1` is therefore `7 == (tot
        # = 1)`, NOT an attempt to assign into `(7 == tot)`.
        node = parse_expr("7 == tot = 1").as(Binary)
        node.op.should eq TokenKind::EqEq
        node.left.as(IntLiteral).value.should eq "7"
        rhs = node.right.as(Assign)
        rhs.target.as(Identifier).name.should eq "tot"
        rhs.value.as(IntLiteral).value.should eq "1"
      end

      it "the same rule applies with + (a + b = 1 parses as a + (b = 1))" do
        node = parse_expr("a + b = 1").as(Binary)
        node.op.should eq TokenKind::Plus
        rhs = node.right.as(Assign)
        rhs.target.as(Identifier).name.should eq "b"
      end
    end

    describe "attribute assignment (recv.attr = value)" do
      it "parses recv.attr = value as a dedicated AttrAssign, not a generic Assign" do
        node = parse_expr("obj.x = 1")
        node.should be_a(AttrAssign)
        aa = node.as(AttrAssign)
        aa.receiver.as(Identifier).name.should eq "obj"
        aa.method.should eq "x"
        aa.value.as(IntLiteral).value.should eq "1"
      end

      it "resolves the receiver correctly for a chained receiver (a.b.c = 1)" do
        node = parse_expr("a.b.c = 1")
        aa = node.as(AttrAssign)
        aa.method.should eq "c"
        recv = aa.receiver.as(Call)
        recv.method.should eq "b"
        recv.receiver.as(Identifier).name.should eq "a"
      end

      it "does NOT build AttrAssign when the call has real arguments (not a bare attribute)" do
        # `foo(1) = 2` was never valid Ruby either — falls back to an
        # ordinary Assign wrapping the Call as its target, which
        # Compiler#emit_store's generic fallback then correctly
        # rejects at compile time (see compiler_spec.cr).
        node = parse_expr("obj.foo(1) = 2")
        node.should be_a(Assign)
        node.as(Assign).target.should be_a(Call)
      end

      it "does NOT build AttrAssign when the call has a block" do
        node = parse_expr("obj.foo { 1 } = 2")
        node.should be_a(Assign)
      end
    end

    describe "multi-target assignment" do
      it "parses two targets with two literal values" do
        node = parse_expr("a, b = 1, 2").as(MultiAssign)
        node.targets.map(&.as(Identifier).name).should eq ["a", "b"]
        node.values.map(&.as(IntLiteral).value).should eq ["1", "2"]
      end

      it "parses a single-expression rhs (array-valued at runtime) without wrapping it" do
        # `a, b = some_array` has one rhs expression, not a comma list —
        # parse_multi_rhs only wraps in ArrayLiteral when it sees a
        # comma; the runtime splat (single Array value -> many targets)
        # is Op::MultiUnpack's job, not the parser's. See vm_spec.
        node = parse_expr("a, b = xs").as(MultiAssign)
        node.targets.size.should eq 2
        node.values.size.should eq 1
        node.values.first.as(Identifier).name.should eq "xs"
      end

      it "parses three targets" do
        node = parse_expr("a, b, c = 1, 2, 3").as(MultiAssign)
        node.targets.size.should eq 3
        node.values.size.should eq 3
      end

      it "registers each identifier target as a local" do
        # a, b = a, 1 — real Ruby's own rule (mirrored by
        # register_local_if_identifier on the single-target path)
        # is that targets are registered only after the whole rhs is
        # parsed, so an as-yet-unassigned `a` on the rhs is still a
        # bare reference, not a read of a not-yet-existing local.
        node = parse_expr("a, b = a, 1").as(MultiAssign)
        node.targets.first.as(Identifier).name.should eq "a"
      end
    end
  end
end
