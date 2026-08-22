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

      it "compiles =~ as a real receiver call on the left operand" do
        # Same shape as <=> just above (compile_match mirrors
        # compile_spaceship exactly) — `a =~ b` desugars to `a.=~(b)`,
        # dispatching on `a`, not on whatever frame happens to be
        # compiling the match.
        chunk = compile("a =~ b")
        inst = chunk.code.find { |i| i.op == Op::Call }.not_nil!
        (inst.b & 0b10_u16).should_not eq(0_u16)
      end

      it "compiles !~ as the same =~ receiver call plus a trailing Not" do
        # Real Ruby's `!~` is generically `!(self =~ other)` — always
        # via `=~` itself, never a separate `!~` method dispatch, same
        # as `!=`/NEq reusing `==`'s own machinery just below rather
        # than being a distinct thing. `compile_match` is reused
        # as-is; `BangTilde` just appends one `Op::Not` right after
        # the `Op::Call` it emits — checking THAT adjacency (not just
        # "a Not appears somewhere") is what actually distinguishes
        # this from, say, a `Not` left over from some other part of
        # the expression.
        chunk = compile("a !~ b")
        call_idx = chunk.code.index { |i| i.op == Op::Call }
        call_idx.should_not be_nil
        chunk.code[call_idx.not_nil! + 1].op.should eq Op::Not
      end

      it "compiles === as a fixed opcode, NOT a receiver call like <=>/=~ (added 2026-08-21)" do
        # Deliberately the opposite shape from the <=> and =~ specs
        # just above: === joined == in OVERLOADABLE_OPERATOR_NAMES
        # (compiler.cr) rather than gaining ordinary dispatch, so
        # unlike those two, this emits NO Op::Call at all — see
        # DEVELOPMENT.md for the full reasoning.
        o = ops("a === b")
        o.should contain(Op::TripleEq)
        o.should_not contain(Op::Call)
      end

      it "compile_case emits Op::TripleEq per when-pattern, not Op::Call" do
        # compile_case used to build a real Op::Call to a "===" symbol
        # (see SCOPE.md's now-resolved "missing receiver bit" entry) —
        # now shares the exact same fixed opcode bare infix === uses,
        # so this and the spec just above should look structurally
        # identical on this point.
        o = ops("case 5\nwhen 1\n  \"a\"\nend")
        o.should contain(Op::TripleEq)
        o.should_not contain(Op::Call)
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
