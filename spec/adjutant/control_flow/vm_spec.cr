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

      {
        "if (a == 1)..(a == 2)\n1\nend",
        "if false\n1\nelsif (a == 1)..(a == 2)\n2\nend",
        "unless (a == 1)...(a == 2)\n1\nend",
        "while (a == 1)..(a == 2)\n1\nend",
        "until (a == 1)..(a == 2)\n1\nend",
        "x = 1 if (a == 1)..(a == 2)",
        "x = 1 unless (a == 1)..(a == 2)",
        "x = 1 while (a == 1)..(a == 2)",
        "x = (a == 1)..(a == 2) ? 1 : 2",
        "if b && ((a == 1)..(a == 2))\n1\nend",
        "if b or (a == 1)..(a == 2)\n1\nend",
        "if !((a == 1)..(a == 2))\n1\nend",
        "if not (a == 1)..(a == 2)\n1\nend",
        "if 1..2\n1\nend",
      }.each do |source|
        it "rejects a flip-flop in #{source.inspect} as U023" do
          error = expect_raises(CompileError) { compile("a = 1\nb = true\n#{source}") }
          error.diagnostic.not_nil!.code.should eq("U023")
        end
      end

      it "places U023 on the range operator" do
        error = expect_raises(CompileError) { compile("a = 1\nif (a == 1)...(a == 2)\n1\nend") }
        span = error.diagnostic.not_nil!.primary.not_nil!
        span.line.should eq(2)
        span.column.should eq(12)
        span.length.should eq(3)
      end

      it "compiles a range held in a variable as a condition, as Ruby does" do
        o = ops("r = 1..2\nif r\n1\nend")
        o.should contain(Op::JumpIfFalse)
      end

      it "compiles a range inside a condition's comparison" do
        o = ops("a = 1\nif (1..2) == (1..2)\n1\nend")
        o.should contain(Op::JumpIfFalse)
      end
    end
  end
end
