require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "binary expressions" do
      it "compiles addition" do
        ops("1 + 2").should contain(Op::Add)
      end

      it "compiles subtraction" do
        ops("3 - 1").should contain(Op::Sub)
      end

      it "compiles multiplication" do
        ops("2 * 3").should contain(Op::Mul)
      end

      it "compiles division" do
        ops("6 / 2").should contain(Op::Div)
      end

      it "compiles modulo" do
        ops("7 % 3").should contain(Op::Mod)
      end

      it "compiles equality" do
        ops("a == b").should contain(Op::Eq)
      end

      it "compiles inequality as Eq + Not" do
        o = ops("a != b")
        o.should contain(Op::Eq)
        o.should contain(Op::Not)
      end

      it "compiles less-than" do
        ops("a < b").should contain(Op::Lt)
      end

      it "compiles <=> as a real receiver call on the left operand" do
        # Found 2026-08-06 while wiring `<`/`<=`/`>`/`>=` through
        # `<=>` (see SCOPE.md): compile_spaceship never set the
        # receiver bit, so `a <=> b` never actually dispatched `<=>`
        # ON `a` — it fell through to implicit-self dispatch against
        # whatever frame happened to be running the comparison. Op is
        # still a plain Op::Call (no dedicated spaceship opcode); the
        # receiver bit is what makes it a real `a.<=>(b)`.
        chunk = compile("a <=> b")
        inst = chunk.code.find { |i| i.op == Op::Call }.not_nil!
        (inst.b & 0b10_u16).should_not eq(0_u16)
      end

      it "compiles short-circuit || with Dup and JumpIfFalse" do
        o = ops("a || b")
        o.should contain(Op::Dup)
        o.should contain(Op::JumpIfFalse)
        o.should contain(Op::Jump)
      end

      it "compiles short-circuit && with Dup and JumpIfFalse" do
        o = ops("a && b")
        o.should contain(Op::Dup)
        o.should contain(Op::JumpIfFalse)
      end
    end
  end
end
