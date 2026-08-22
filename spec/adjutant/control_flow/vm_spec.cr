require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "control flow" do
      it "evaluates if-then" do
        eval("if true\n42\nend").as_int.should eq 42_i64
      end

      it "evaluates the else branch" do
        eval("if false\n1\nelse\n2\nend").as_int.should eq 2_i64
      end

      it "evaluates elsif" do
        eval("x = 2\nif x == 1\n:one\nelsif x == 2\n:two\nelse\n:other\nend").as_sym.name.should eq "two"
      end

      it "evaluates unless" do
        eval("unless false\n:yes\nend").as_sym.name.should eq "yes"
      end

      it "evaluates ternary" do
        eval("1 > 0 ? :yes : :no").as_sym.name.should eq "yes"
      end

      it "evaluates a while loop" do
        eval("x = 0\nwhile x < 3\nx += 1\nend\nx").as_int.should eq 3_i64
      end

      it "evaluates modifier if" do
        eval("x = 1\nx = 2 if true\nx").as_int.should eq 2_i64
      end

      it "evaluates modifier unless" do
        eval("x = 1\nx = 2 unless false\nx").as_int.should eq 2_i64
      end

      it "evaluates modifier while with check-first semantics: the " \
         "body never runs if the condition is false from the start" do
        # Regression coverage for a bug found 2026-08-06:
        # compile_modifier_while (compiler.cr) previously compiled
        # EVERY `expr while cond` with check-LAST semantics (body
        # always runs at least once) — correct only for the do-while
        # `begin...end while cond` form (now rejected outright,
        # see U016 in UNSUPPORTED.md), silently wrong for this,
        # the ordinary and far more common form. Real Ruby: `x -=
        # 1 while x > 10` starting at x = 5 must never touch x at
        # all, since 5 > 10 is false before the body ever runs once.
        eval("x = 5\nx -= 1 while x > 10\nx").as_int.should eq 5_i64
      end

      it "evaluates modifier while normally when the condition starts " \
         "true, running until it goes false" do
        # Sibling check to the one above — confirms the check-first
        # fix didn't overcorrect into never running the body at all.
        eval("x = 0\nx += 1 while x < 3\nx").as_int.should eq 3_i64
      end

      it "evaluates modifier until with the same check-first semantics" do
        eval("x = 5\nx -= 1 until x < 10\nx").as_int.should eq 5_i64
      end
    end

    # Regression coverage for two bugs found while testing Range#each
    # support (2026-07-14 session): compile_for never set the
    # receiver bit on its emitted Call, so `for x in expr` dispatched
    # a receiverless bare `each` ("undefined method or variable:
    # each") instead of `expr.each`; separately, the "block" it built
    # was a hardcoded nil constant, so node.vars/node.body were never
    # compiled — even a correctly-dispatched each would have run an
    # empty/no-op block.
    describe "for loop" do
      it "iterates an array, binding the loop variable each pass" do
        src = <<-RUBY
        total = 0
        for x in [1, 2, 3, 4]
          total += x
        end
        total
        RUBY
        eval(src).as_int.should eq 10
      end

      it "iterates with the do keyword" do
        src = <<-RUBY
        total = 0
        for x in [1, 2, 3] do
          total += x
        end
        total
        RUBY
        eval(src).as_int.should eq 6
      end

      it "iterates over a bare-identifier array variable (not just a literal)" do
        src = <<-RUBY
        a = [1, 3, 5, 7, 9]
        total = 0
        for o in a
          total += o
        end
        total
        RUBY
        eval(src).as_int.should eq 25
      end

      it "iterates over a bare-identifier array variable with do" do
        src = <<-RUBY
        a = [1, 3, 5, 7, 9]
        total = 0
        for o in a do
          total += o
        end
        total
        RUBY
        eval(src).as_int.should eq 25
      end

      it "the loop body actually runs, not a no-op" do
        src = <<-RUBY
        seen = []
        for x in [10, 20]
          seen << x
        end
        seen
        RUBY
        result = eval(src)
        result.as_array.map(&.as_int).should eq [10, 20]
      end

      it "works as a for-loop's iterable, inclusive" do
        src = <<-RUBY
        total = 0
        for x in 1..4
          total += x
        end
        total
        RUBY
        eval(src).as_int.should eq 10
      end

      it "works as a for-loop's iterable, exclusive" do
        src = <<-RUBY
        total = 0
        for x in 1...4
          total += x
        end
        total
        RUBY
        eval(src).as_int.should eq 6
      end
    end

    # Regression coverage for the same do-ambiguity found in `for`,
    # reported separately for `while`/`until`: a parenless dot-call
    # (`a.size`) as the rightmost primary in the condition, followed
    # by `do`, used to be swallowed as `a.size do ... end` — a call
    # with a block — consuming the while-loop's own `end`.
    describe "while loop with trailing do" do
      it "parses and runs a while condition ending in a bare identifier" do
        src = <<-RUBY
        i = 0
        running = true
        while running do
          i += 1
          running = false if i >= 3
        end
        i
        RUBY
        eval(src).as_int.should eq 3
      end

      it "parses and runs a while condition ending in a dot-call (a.size)" do
        src = <<-RUBY
        a = [1, 3, 5, 7, 9]
        i = 0
        while i < a.size do
          o = a[i]
          i += 1
        end
        i
        RUBY
        eval(src).as_int.should eq 5
      end
    end

    describe "case/when" do
      # No VM-level test for case/when existed anywhere in the repo
      # before this (see SCOPE.md, "Verified only up to compile time,
      # never actually run") — found while surveying spec coverage for
      # a prior session's test-spec reorg, never actually addressed
      # until now, working the === item this depends on directly.

      it "matches a literal value" do
        eval("case 5\nwhen 5\n  \"five\"\nelse\n  \"other\"\nend").as_string.should eq("five")
      end

      it "falls through to else when no pattern matches" do
        eval("case 5\nwhen 1\n  \"one\"\nelse\n  \"other\"\nend").as_string.should eq("other")
      end

      # SCOPE.md's === item (now resolved — see DEVELOPMENT.md): the
      # old exec_builtin "===" fallback used to be plain values_equal?
      # (==) for every receiver, so `when Integer`/`when a_range`
      # compiled and ran with no error but never matched — a silent
      # wrong answer, not a crash, which is exactly why it went
      # unnoticed without a VM-level test. Now runs through
      # Op::TripleEq (vm.cr's triple_eq_matches?), shared with bare
      # infix `a === b` (see spec/adjutant/operators/vm_spec.cr).
      it "matches by type with a Class pattern (Class#===)" do
        eval("case 5\nwhen Integer\n  \"matched\"\nelse\n  \"no match\"\nend")
          .as_string.should eq("matched")
      end

      it "does not match a Class pattern for the wrong type" do
        eval("case \"x\"\nwhen Integer\n  \"matched\"\nelse\n  \"no match\"\nend")
          .as_string.should eq("no match")
      end

      it "matches by membership with a Range pattern (Range#===)" do
        eval("case 5\nwhen 1..10\n  \"in range\"\nelse\n  \"out of range\"\nend")
          .as_string.should eq("in range")
      end

      it "respects an exclusive Range's upper bound" do
        eval("case 10\nwhen 1...10\n  \"in range\"\nelse\n  \"out of range\"\nend")
          .as_string.should eq("out of range")
      end

      it "does not match a Range pattern outside its bounds" do
        eval("case 20\nwhen 1..10\n  \"in range\"\nelse\n  \"out of range\"\nend")
          .as_string.should eq("out of range")
      end

      it "matches by calling a Proc/lambda pattern and checking truthiness (Proc#===)" do
        # Added alongside the 2026-08-21 Op::TripleEq work — not in
        # the original === fix, but a real, reachable pattern (Proc#
        # call already works) worth covering from the start rather
        # than left as a future gap.
        eval("case 4\nwhen ->(x) { x.even? }\n  \"matched\"\nelse\n  \"no match\"\nend")
          .as_string.should eq("matched")
      end

      it "does not match a Proc/lambda pattern whose call returns falsy" do
        eval("case 5\nwhen ->(x) { x.even? }\n  \"matched\"\nelse\n  \"no match\"\nend")
          .as_string.should eq("no match")
      end

      it "still falls back to == for an ordinary literal pattern" do
        # Regression check: the Class/Range/Proc special-casing in
        # Op::TripleEq must not touch the plain-value path.
        eval("case 5\nwhen 3, 5, 7\n  \"odd\"\nelse\n  \"other\"\nend")
          .as_string.should eq("odd")
      end
    end

    # `break` inside a block passed to a NATIVE method (Array#each,
    # Range#each, any of them) — see SCOPE.md's now-resolved Must Fix
    # entry for the full bug this covers, and BlockBreakSignal's own
    # comment (vm.cr) for the fix's mechanism. No prior coverage
    # existed for this shape at all — every existing break spec (see
    # begin_rescue_ensure/vm_spec.cr's "break/next through begin/
    # rescue/ensure") covers break inside a LITERAL loop construct
    # (while/for), a completely different, already-correct code path
    # (a compile-time Jump, not Op::BlockBreak) that this fix doesn't
    # touch at all.
    describe "break inside a block passed to a native method" do
      it "stops the native iteration early — Array#each" do
        result = eval(<<-RUBY)
          seen = []
          [1, 2, 3, 4, 5].each do |n|
            if n > 3
              break
            end
            seen << n
          end
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3]
      end

      it "the break's value becomes the WHOLE call's own result, matching real Ruby" do
        result = eval(<<-RUBY)
          [1, 2, 3].each do |n|
            break 99 if n == 2
          end
        RUBY
        result.as_int.should eq 99
      end

      it "a bare break (no value) makes the call's result nil" do
        result = eval(<<-RUBY)
          [1, 2, 3].each do |n|
            if n == 2
              break
            end
          end
        RUBY
        result.null?.should be_true
      end

      it "an inner native call's break doesn't disturb an outer one's own iteration" do
        result = eval(<<-RUBY)
          outer_seen = []
          [10, 20].each do |x|
            [1, 2, 3].each do |y|
              if y == 2
                break
              end
            end
            outer_seen << x
          end
          outer_seen
        RUBY
        result.as_array.map(&.as_int).should eq [10, 20]
      end

      it "is script-catchable — BlockBreakSignal must never surface as an uncaught VM crash" do
        # Not a script-rescue case (break isn't an exception a script
        # ever sees) — this just confirms the whole call completes
        # normally end to end, rather than a raw Crystal
        # BlockBreakSignal escaping uncaught past `eval` itself: if it
        # did, THIS raise (an ordinary script-level one, deliberately
        # placed right after the break-using call) would never be
        # reached at all, and expect_raises below would fail with
        # "no exception raised" rather than matching this message.
        expect_raises(RuntimeError, /nothing to see here — should not raise/) do
          eval(<<-RUBY)
            [1].each do
              break
            end
            raise "nothing to see here — should not raise"
          RUBY
        end
      end
    end

    # `break` inside a block invoked via `yield` (as opposed to via a
    # native method's `ncc.invoke` — see the describe block above) —
    # see SCOPE.md's now-resolved entry for the full bug and fix.
    # `Op::Yield` shares `@frames` with its caller (no
    # `invoke_internal` isolation), so `break` here can't use the same
    # raise-to-`call_native` mechanism the native case does — instead,
    # once the consecutive block-frame unwind lands on a REAL frame,
    # `Frame#block` (exactly what `Op::Yield` itself reads to find the
    # block to invoke) identifies whether that landed frame is
    # genuinely the one that yielded to this chain; if so it's
    # terminated too, Ret-style, rather than resumed past the `yield`
    # site.
    describe "break inside a yielded-to block" do
      it "ends the calling method's own call immediately, matching real Ruby" do
        result = eval(<<-RUBY)
          def foo
            yield
            "after"
          end
          foo do
            break
          end
        RUBY
        result.null?.should be_true
      end

      it "the break's value becomes the WHOLE method call's own result" do
        result = eval(<<-RUBY)
          def foo
            yield
            "after"
          end
          foo do
            break 99
          end
        RUBY
        result.as_int.should eq 99
      end

      it "the method's own caller continues normally afterward" do
        result = eval(<<-RUBY)
          def foo
            yield
            "after"
          end
          x = foo { break 1 }
          y = 2
          [x, y]
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2]
      end

      it "works when the yielding method is itself called from inside a native method's block" do
        result = eval(<<-RUBY)
          def foo
            yield
            "after"
          end
          seen = []
          [1, 2].each do |x|
            foo do
              break
            end
            seen << x
          end
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2]
      end
    end
  end
end
