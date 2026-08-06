require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "begin/rescue" do
      it "compiles begin/rescue with Try and EndTry" do
        o = ops("begin\n1\nrescue e\n2\nend")
        o.should contain(Op::Try)
        o.should contain(Op::EndTry)
      end

      # do-while (`begin...end while cond`) is a deliberate exclusion
      # (see UNSUPPORTED.md, U016) — real Ruby gives this ONE form
      # of the while/until modifier different (check-last) semantics
      # than every other use of the same keyword (check-first). The
      # BARE-statement form never reaches the compiler at all — it
      # is rejected earlier, at parse time (see parser_spec.cr's own
      # U016 coverage) — so these tests cover the ASSIGNED forms
      # (`x = begin...end while cond` and its compound-assignment
      # siblings), the only ways this construct successfully parses
      # into a real ModifierWhile node at all.
      it "rejects the assigned begin...end while (do-while) form " \
         "at compile time" do
        expect_raises(CompileError, /do-while/) do
          compile("x = begin\n1\nend while true")
        end
      end

      it "carries a U016 diagnostic spanning the `begin` keyword, not " \
         "the assignment target" do
        error = expect_raises(CompileError) do
          compile("x = begin\n1\nend while true")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("U016")
        span = diag.primary.not_nil!
        span.line.should eq(1)
        # Column 5 is "begin" itself (after "x = "), not column 1
        # where "x" starts — guards against the span accidentally
        # pointing at the assignment target instead of the do-while
        # trigger, which line alone can't distinguish when both
        # happen to share a line the way this source does.
        span.column.should eq(5)
        span.length.should eq(5) # "begin"
      end

      it "rejects the assigned begin...end until (do-while) form too" do
        expect_raises(CompileError, /do-while/) do
          compile("x = begin\n1\nend until false")
        end
      end

      it "rejects a compound-assigned begin...end while (do-while) " \
         "form too, not just plain `=`" do
        # Regression coverage for a bug found 2026-08-06: the first
        # version of this check tested `node.body.is_a?(BeginNode)`
        # directly, but node.body for the assigned form is the
        # Assign/OpAssign/CondAssign node itself (what
        # parse_expr_statement actually wraps in ModifierWhile), not
        # the BeginNode buried inside its `value` field — so `x =
        # begin...end while cond` never matched at all and silently
        # compiled as a (wrong) do-while loop instead of being
        # rejected. `+=`/`-=`/etc. share the same shape one level
        # deeper and needed the same unwrap.
        expect_raises(CompileError, /do-while/) do
          compile("x = 0\nx += begin\n1\nend while true")
        end
      end

      it "does not reject an ordinary plain-expression modifier while" do
        # Regression guard for the checks above — an ordinary
        # expression modifier-while (not wrapping a BeginNode) must
        # compile cleanly; only the begin-wrapped form is excluded.
        o = ops("y = 1\ny -= 1 while false")
        o.should contain(Op::JumpIfFalse)
      end
    end
  end
end
