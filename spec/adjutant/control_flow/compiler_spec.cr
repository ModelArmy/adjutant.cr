require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "control flow" do
      it "compiles if with JumpIfFalse and Jump" do
        o = ops("if x\n1\nend")
        o.should contain(Op::JumpIfFalse)
        o.should contain(Op::Jump)
      end

      it "compiles unless with Not" do
        o = ops("unless x\n1\nend")
        o.should contain(Op::JumpIfFalse)
      end

      it "compiles ternary" do
        o = ops("x ? 1 : 2")
        o.should contain(Op::JumpIfFalse)
        o.should contain(Op::Jump)
      end

      it "compiles while with back-jump" do
        o = ops("while x\nx\nend")
        o.should contain(Op::JumpIfFalse)
        o.should contain(Op::Jump)
      end

      it "compiles return" do
        # def compiles to MakeProc + SetGlobal; body is in the proc's chunk
        chunk = compile("def f\nreturn 1\nend")
        chunk.code.map(&.op).should contain(Op::MakeProc)
        proc_val = chunk.consts.find { |v| v.proc? }
        proc_val.should_not be_nil
      end

      it "compiles modifier if" do
        o = ops("x = 1 if true")
        o.should contain(Op::JumpIfFalse)
      end
    end
  end
end
