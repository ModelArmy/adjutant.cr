require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "assignment" do
      it "compiles simple top-level assignment with SetLocal, not SetGlobal" do
        # Previously x = 1 at top level compiled to SetGlobal — the
        # exact bug the 2026-07-15 scoping fix corrects (see
        # Compiler.compile/CompilerScope). A bare top-level assignment
        # is now a real local, matching real Ruby (SetGlobal is
        # reserved for `def` at top level, and $global-style globals
        # once those land — never a plain `x = 1`).
        o = ops("x = 1")
        o.should contain(Op::SetLocal)
        o.should_not contain(Op::SetGlobal)
      end

      it "compiles ivar assignment with SetIvar" do
        ops("@x = 1").should contain(Op::SetIvar)
      end

      it "compiles cvar assignment with SetCvar" do
        ops("@@x = 1").should contain(Op::SetCvar)
      end

      it "compiles += as load, add, store, all against the local — not global" do
        o = ops("x = 0\nx += 1")
        o.should contain(Op::GetLocal)
        o.should contain(Op::Add)
        o.should contain(Op::SetLocal)
        o.should_not contain(Op::SetGlobal)
      end

      # A compound assignment into an index pushes the receiver and
      # index once, reads through copies of them (DupN, GetIndex), and
      # writes through the originals with SetIndex.
      it "compiles x[i] += 1 to one read through DupN and one SetIndex" do
        o = ops("x = [0]\nx[0] += 1")
        o.count(Op::DupN).should eq 1
        o.count(Op::SetIndex).should eq 1
        o.should_not contain(Op::SetIndexFromValue)
      end

      it "compiles x[i] ||= v the same way, with PopUnder for when it doesn't assign" do
        o = ops("x = [nil]\nx[0] ||= 5")
        o.should contain(Op::PopUnder)
        o.count(Op::SetIndex).should eq 1
        o.should_not contain(Op::SetIndexFromValue)
      end
    end

    describe "multi-target assignment" do
      it "gathers a, b = 1, 2 into one Array before MultiUnpack, for 2 targets" do
        code = compile("a, b = 1, 2").code
        make = code.index { |inst| inst.op == Op::MakeArray }
        unpack = code.index { |inst| inst.op == Op::MultiUnpack }
        (make && unpack && make < unpack).should be_true
        unpack.try { |at| code[at].a.should eq 2 }
      end

      it "compiles a, b = xs as one value, kept as the assignment's value, before MultiUnpack" do
        o = ops("a, b = xs")
        o.should_not contain(Op::MakeArray)
        unpack = o.index(Op::MultiUnpack)
        unpack.should_not be_nil
        unpack.try { |at| o[at - 1].should eq Op::Dup }
      end
    end

    describe "attribute assignment (recv.attr = value)" do
      it "compiles recv.attr = value to Op::SetAttr, not a generic Set*" do
        o = ops("obj.x = 1")
        o.should contain(Op::SetAttr)
        o.should_not contain(Op::SetIvar)
        o.should_not contain(Op::SetLocal)
        o.should_not contain(Op::SetIndex)
      end

      it "pushes the receiver before the value (receiver evaluated once, first)" do
        # Op::SetAttr's own contract (see its comment, bytecode.cr):
        # pop value, pop receiver — meaning receiver must have been
        # pushed FIRST. Two Op::Const pushes precede Op::SetAttr for
        # `obj.x = 1` (well: obj is a local, so Op::GetLocal, then the
        # literal 1 via Op::Const) — assert the relative order rather
        # than exact opcodes, so this doesn't overfit to how `obj`
        # happens to compile.
        chunk = compile("obj = nil\nobj.x = 1")
        set_attr_idx = chunk.code.index { |i| i.op == Op::SetAttr }.not_nil!
        # The instruction immediately before Op::SetAttr must be the
        # VALUE push (a Const for the literal 1); the receiver push
        # (a GetLocal for `obj`) comes before that.
        chunk.code[set_attr_idx - 1].op.should eq Op::Const
        chunk.code[set_attr_idx - 2].op.should eq Op::GetLocal
      end

      it "an attribute-assignment expression's own compiled shape has no C001-triggering fallback" do
        # Regression for the original bug report: `recv.attr = value`
        # must not hit emit_store's generic `Call`-is-unassignable
        # raise at all anymore.
        ops("obj.x = 1")
      end

      it "obj.foo(1) = 2 (a Call target with real args) still raises C001, unaffected by AttrAssign" do
        # AttrAssign only ever gets built for a bare, arg-less
        # attribute reference (see parser_spec.cr) — anything else
        # remains an ordinary Assign wrapping a Call target, which
        # emit_store's generic fallback correctly still rejects.
        expect_raises(CompileError, /cannot assign to a method call/) do
          compile("obj.foo(1) = 2")
        end
      end
    end
  end
end
