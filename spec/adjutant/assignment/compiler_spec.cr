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
    end

    describe "multi-target assignment" do
      it "compiles a, b = 1, 2 with MultiUnpack, target_count 2, value_count 2" do
        chunk = compile("a, b = 1, 2")
        inst = chunk.code.find { |i| i.op == Op::MultiUnpack }.not_nil!
        inst.a.should eq 2
        inst.b.should eq 2
      end

      it "compiles a, b = xs with value_count 1 (splat is the VM's job, not the compiler's)" do
        chunk = compile("a, b = xs")
        inst = chunk.code.find { |i| i.op == Op::MultiUnpack }.not_nil!
        inst.a.should eq 2
        inst.b.should eq 1
      end
    end
  end
end
