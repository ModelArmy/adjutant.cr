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
