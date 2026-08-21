require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "variables" do
      it "assigns and reads a variable" do
        eval("x = 42\nx").as_int.should eq 42_i64
      end

      it "reassigns a variable" do
        eval("x = 1\nx = 2\nx").as_int.should eq 2_i64
      end

      it "evaluates compound assignment +=" do
        eval("x = 10\nx += 5\nx").as_int.should eq 15_i64
      end

      it "evaluates ||= when nil" do
        eval("x = nil\nx ||= 42\nx").as_int.should eq 42_i64
      end

      it "evaluates ||= when already set" do
        eval("x = 1\nx ||= 99\nx").as_int.should eq 1_i64
      end

      it "chained assignment (c = b = 5) assigns both targets, right-associatively" do
        eval("c = b = 5\nb + c").as_int.should eq 10_i64
      end

      it "an assignment nested in parens evaluates to a real, usable value" do
        eval("x = (y = 5) + 1\nx").as_int.should eq 6_i64
      end
    end

    describe "compound/conditional assignment into an index target" do
      # Found 2026-08-08: this shape (`x[i] += 1`, `x[i] ||= v`, and
      # a MultiAssign target that's an Index) went through a
      # completely different, silently-broken code path from plain
      # `x[i] = v` — see Op::SetIndexFromValue's own comment
      # (bytecode.cr) for the full trace. No spec had ever exercised
      # any of these three shapes before.
      it "x[i] += 1 actually increments the element, not silently no-ops" do
        eval("x = [10]\nx[0] += 5\nx[0]").as_int.should eq 15_i64
      end

      it "x[i] -= n works too, not just +=" do
        eval("x = [10]\nx[0] -= 3\nx[0]").as_int.should eq 7_i64
      end

      it "x[i] ||= v assigns when the element is nil" do
        eval("x = [nil]\nx[0] ||= 42\nx[0]").as_int.should eq 42_i64
      end

      it "x[i] ||= v leaves an already-truthy element untouched" do
        eval("x = [1]\nx[0] ||= 99\nx[0]").as_int.should eq 1_i64
      end

      it "works on a Hash index target too, not just Array" do
        eval(%(h = {"a" => 1}\nh["a"] += 10\nh["a"])).as_int.should eq 11_i64
      end

      it "does not disturb an UNRELATED element" do
        eval("x = [1, 2, 3]\nx[1] += 100\nx[0]").as_int.should eq 1_i64
      end

      it "also fixed for a MultiAssign target that's an index (the third affected call site)" do
        result = eval("x = [0, 0]\nb = nil\nx[0], b = 5, 9\n[x[0], b]").as_array
        result[0].as_int.should eq 5_i64
        result[1].as_int.should eq 9_i64
      end
    end

    describe "multi-target assignment" do
      it "assigns from a literal comma list" do
        eval("a, b = 1, 2\n[a, b]").as_array[0].as_int.should eq 1_i64
        eval("a, b = 1, 2\n[a, b]").as_array[1].as_int.should eq 2_i64
      end

      it "swaps two variables with no temp" do
        eval("a = 1\nb = 2\na, b = b, a\na").as_int.should eq 2_i64
        eval("a = 1\nb = 2\na, b = b, a\nb").as_int.should eq 1_i64
      end

      it "splats a single Array-valued rhs across targets" do
        result = eval("a, b = [1, 2]\n[a, b]").as_array
        result[0].as_int.should eq 1_i64
        result[1].as_int.should eq 2_i64
      end

      it "splats an array from a variable, not just a literal" do
        result = eval("xs = [10, 20]\na, b = xs\n[a, b]").as_array
        result[0].as_int.should eq 10_i64
        result[1].as_int.should eq 20_i64
      end

      it "pads with nil when there are more targets than values" do
        result = eval("a, b, c = 1, 2\n[a, b, c]").as_array
        result[2].null?.should be_true
      end

      it "truncates extra values when there are more values than targets" do
        result = eval("a, b = 1, 2, 3\n[a, b]").as_array
        result[0].as_int.should eq 1_i64
        result[1].as_int.should eq 2_i64
      end

      it "does not splat a non-array single value" do
        result = eval("a, b = 5\n[a, b]").as_array
        result[0].as_int.should eq 5_i64
        result[1].null?.should be_true
      end

      it "does not splat when a literal array is only one of several rhs values" do
        # a, b = [1, 2], 3 — two rhs values at the top level, so no
        # runtime splat applies; a gets the array itself, b gets 3.
        result = eval("a, b = [1, 2], 3\n[a, b]").as_array
        result[0].as_array[0].as_int.should eq 1_i64
        result[0].as_array[1].as_int.should eq 2_i64
        result[1].as_int.should eq 3_i64
      end
    end

    describe "attribute assignment (recv.attr = value)" do
      it "calls the setter, and it's visible via the getter afterward" do
        val = eval(<<-RUBY)
          class Box
            attr_accessor :value
          end
          b = Box.new
          b.value = 42
          b.value
          RUBY
        val.as_int.should eq 42_i64
      end

      it "the assignment expression's own value is what was assigned, never the setter's return value" do
        # `value=`'s body deliberately returns something else — real
        # Ruby (and this) still evaluates a `recv.attr = value`
        # expression to `value`, not to the setter's own return
        # value. Same contract every other Set* opcode already has
        # (Op::SetIvar/Op::SetIndex/...). Now asserted the natural way
        # — capturing the parenthesized/nested assignment's own value
        # directly — since `parse_expression` resolving assignment
        # inside its own chain (not just at the statement level) is no
        # longer a gap; see DEVELOPMENT.md's "Assignment as a real
        # expression" entry.
        val = eval(<<-RUBY)
          class Weird
            def value=(v)
              @value = v
              "something else entirely"
            end

            def value
              @value
            end
          end
          w = Weird.new
          result = (w.value = 5)
          result
          RUBY
        val.as_int.should eq 5_i64
      end

      it "evaluates a receiver expression with side effects exactly once, not twice" do
        # Regression for the exact bug `compile_attr_assign` exists to
        # avoid (see that method's own comment, compiler.cr): a naive
        # "reuse emit_store's generic dispatch" approach would have
        # recompiled the receiver expression, calling it twice.
        val = eval(<<-RUBY)
          class Config
            attr_accessor :value
          end

          CFG = Config.new
          CALLS = [0]

          def get_cfg
            CALLS[0] += 1
            CFG
          end

          get_cfg.value = 42
          [CALLS[0], CFG.value]
          RUBY
        arr = val.as_array
        arr[0].as_int.should eq 1_i64
        arr[1].as_int.should eq 42_i64
      end

      it "raises when the receiver's class defines no matching setter" do
        expect_raises(RuntimeError) do
          eval("class Empty\nend\nEmpty.new.foo = 1")
        end
      end

      it "resolves through a chained receiver (a.b.c = 1)" do
        val = eval(<<-RUBY)
          class Inner
            attr_accessor :c
          end
          class Outer
            def b
              @b ||= Inner.new
            end
          end
          a = Outer.new
          a.b.c = 7
          a.b.c
          RUBY
        val.as_int.should eq 7_i64
      end
    end
  end
end
