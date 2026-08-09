require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "methods and closures" do
      it "calls a def with params" do
        src = <<-RUBY
        def add(a, b)
          a + b
        end
        add(3, 4)
        RUBY
        eval(src).as_int.should eq 7_i64
      end

      # See methods_and_calls/parser_spec.cr's own comment on the
      # matching parser fix for the full trace — a hand-written
      # `def name=(v)` had never been parseable before this session.
      it "calls a hand-written setter method def (name=) via recv.attr = value" do
        src = <<-RUBY
        class Box
          def value=(v)
            @stored = v * 2
          end

          def stored
            @stored
          end
        end
        b = Box.new
        b.value = 21
        b.stored
        RUBY
        eval(src).as_int.should eq 42_i64
      end

      it "isolates method locals from global scope" do
        src = <<-RUBY
        x = 1
        def set_x
          x = 99
        end
        set_x
        x
        RUBY
        eval(src).as_int.should eq 1_i64
      end

      it "evaluates a recursive method" do
        src = <<-RUBY
        def fact(n)
          return 1 if n < 2
          n * fact(n - 1)
        end
        fact(5)
        RUBY
        eval(src).as_int.should eq 120_i64
      end

      it "supports multiple params" do
        src = <<-RUBY
        def greet(a, b, c)
          a + b + c
        end
        greet(1, 2, 3)
        RUBY
        eval(src).as_int.should eq 6_i64
      end

      it "supports local variables inside a method" do
        src = <<-RUBY
        def double(n)
          result = n * 2
          result
        end
        double(21)
        RUBY
        eval(src).as_int.should eq 42_i64
      end

      it "supports default-nil return when body is empty" do
        src = <<-RUBY
        def noop()
        end
        noop()
        RUBY
        eval(src).null?.should be_true
      end

      it "yields to a block" do
        src = <<-RUBY
        def call_block
          yield 10
        end
        call_block { |x| x * 2 }
        RUBY
        eval(src).as_int.should eq 20_i64
      end

      it "block does not capture enclosing local via closure" do
        src = <<-RUBY
        def run
          total = 0
          yield 1
          yield 2
          yield 3
          total
        end
        run { |x| total += x }
        RUBY
        expect_raises(Adjutant::RuntimeError) do
          eval(src)
        end
      end

      # Fixed 2026-07-15 (same session as A's scoping fix, as a direct
      # follow-up): a block's closure capture now correctly comes from
      # the frame it was CREATED in (captured at Op::SetBlock time,
      # carried on the callee's Frame#block_outer_locals, read by
      # Op::Yield) rather than whatever frame happens to be executing
      # when yield later fires. Previously masked by the pre-A bug
      # (top-level locals were accidentally globals, so this worked by
      # accident regardless of which frame outer_locals pointed at).
      it "block captures local from its defining scope via yield" do
        src = <<-RUBY
        total = 0
        def apply
          yield 1
          yield 2
          yield 3
        end
        apply { |x| total += x }
        total
        RUBY
        eval(src).as_int.should eq 6_i64
      end
      it "computes fibonacci recursively" do
        src = <<-RUBY
        def fib(n)
          return n if n < 2
          fib(n - 1) + fib(n - 2)
        end
        fib(3)
        RUBY
        eval(src).as_int.should eq 2_i64
      end

      it "a def from one eval call is callable, and composes correctly, in a later eval call" do
        # Split from an earlier version of this spec that also tried
        # to accumulate into a plain top-level variable ACROSS eval
        # calls — that relied on the same accidental persistence the
        # 2026-07-15 scoping fix corrects (see "shared symbol table
        # across evals" above). The part worth keeping is real: a def
        # genuinely does persist across eval calls, and repeated calls
        # to it within one later eval call correctly compose using
        # THAT call's own local (fresh CompilerScope per eval call,
        # but perfectly normal accumulation within a single one).
        interp, _ = make_interp
        src = <<-RUBY
        def add_one(n)
          n + 1
        end
        RUBY
        interp.eval(src)
        src = <<-RUBY
        total = 0
        total = add_one(total)
        total = add_one(total)
        total = add_one(total)
        total
        RUBY
        interp.eval(src).as_int.should eq 3_i64
      end
    end

    # VM-level coverage for the 2026-08-03 argument-binding fix
    # (SCOPE.md's Must Fix — defaults/splats half). spec/scripts/
    # language/default_params.rb and splat_params.rb already cover the
    # core def-site cases end-to-end via the `assert` script framework;
    # these specs instead use eval's returned Value directly (so they
    # can assert on array CONTENTS, not just equality) and cover shapes
    # those two files don't: defaults/splats combined in one param
    # list, and defaults/splats on lambdas and block literals — not
    # just plain `def` — since Compiler#compile_proc's prologue and
    # VM#bind_args are shared across all three call sites (compile_def,
    # compile_lambda, compile_call's block-literal branch).
    describe "argument binding — defaults and splats" do
      it "combines a default param and a trailing splat in one signature" do
        src = <<-RUBY
        def f(a, b = 10, *rest)
          [a, b, rest]
        end
        f(1)
        RUBY
        v = eval(src)
        v.as_array[0].as_int.should eq 1_i64
        v.as_array[1].as_int.should eq 10_i64  # b's default applied
        v.as_array[2].as_array.should be_empty # rest collects nothing
      end

      it "an explicit arg overrides the default even when a splat follows it" do
        src = <<-RUBY
        def f(a, b = 10, *rest)
          [a, b, rest]
        end
        f(1, 2, 3, 4)
        RUBY
        v = eval(src)
        v.as_array[1].as_int.should eq 2_i64 # explicit, not the default
        v.as_array[2].as_array.map(&.as_int).should eq [3_i64, 4_i64]
      end

      it "a lambda's default param applies when omitted" do
        src = <<-RUBY
        f = ->(x = 5) { x }
        f.call
        RUBY
        eval(src).as_int.should eq 5_i64
      end

      it "a lambda's default param is overridden when supplied" do
        src = <<-RUBY
        f = ->(x = 5) { x }
        f.call(9)
        RUBY
        eval(src).as_int.should eq 9_i64
      end

      it "a lambda's splat param collects extra call args" do
        src = <<-RUBY
        f = ->(*xs) { xs }
        f.call(1, 2, 3)
        RUBY
        eval(src).as_array.map(&.as_int).should eq [1_i64, 2_i64, 3_i64]
      end

      it "a block literal's default param applies when the yielded value list is short" do
        # each_pair-style: the block wants 2 params but the caller
        # only yields 1 value for this iteration.
        src = <<-RUBY
        def once
          yield 7
        end
        once { |a, b = 99| [a, b] }
        RUBY
        v = eval(src)
        v.as_array[0].as_int.should eq 7_i64
        v.as_array[1].as_int.should eq 99_i64
      end

      it "a splat param collects a genuinely empty array (not nil) when nothing remains" do
        src = <<-RUBY
        def f(*rest)
          rest
        end
        f
        RUBY
        v = eval(src)
        v.array?.should be_true
        v.as_array.should be_empty
      end

      it "a required param before a splat still binds correctly when over-supplied" do
        src = <<-RUBY
        def f(first, *rest)
          first
        end
        f(1, 2, 3)
        RUBY
        eval(src).as_int.should eq 1_i64
      end
    end

    describe "bare global identifier resolution" do
      # @globals holds both top-level `def`s and top-level variable
      # assignments in one namespace (unlike Ruby, which keeps methods
      # and variables separate). A bare identifier that isn't a local
      # resolves through @globals; if what's found there is a
      # ScriptProc, it must have come from `def`, so it's called with
      # zero args — otherwise `def foo; ...; end; foo` would silently
      # push the uncalled proc instead of running the method.
      it "calls a top-level def when referenced bare (no parens)" do
        src = <<-RUBY
        def answer
          42
        end
        answer
        RUBY
        eval(src).as_int.should eq 42_i64
      end

      it "still returns a plain value for a non-callable global" do
        src = <<-RUBY
        x = 7
        def set_x_elsewhere
          x = 1
        end
        x
        RUBY
        eval(src).as_int.should eq 7_i64
      end

      # Previously a known limitation (documented, not silently
      # regressed): because top-level `def`s and top-level variable
      # assignments shared one @globals namespace, a bare reference to
      # a variable holding a lambda was indistinguishable from a bare
      # reference to a method, so it was auto-invoked — diverging from
      # real Ruby, where a local variable is NEVER auto-called on bare
      # reference regardless of what it holds. Fixed by giving
      # top-level code (and class/module bodies) a real CompilerScope
      # — `greet = ->() { ... }` now compiles to a genuine
      # Op::SetLocal, so a bare `greet` afterward is Op::GetLocal (the
      # proc VALUE, unevaluated), never Op::GetGlobal's
      # call-if-it's-a-ScriptProc path at all. Asserted via
      # .robject?/rclass.name, not .proc? — Piece C (SCOPE.md) wraps a
      # Lambda literal's ScriptProc in a real Proc RubyObject
      # (builtins/proc.cr), so the local now holds a robject, not a
      # bare proc-kind Value; `.call` (Proc#call) works too as of that
      # piece, this spec just checks proc-ness via the Value directly
      # since that's what it's actually testing (local vs. global
      # resolution, not Proc#call itself).
      it "does NOT auto-invoke a top-level local variable holding a lambda" do
        src = <<-RUBY
        greet = ->() { "hi" }
        greet
        RUBY
        result = eval(src)
        result.robject?.should be_true
        result.as_robject.rclass.name.should eq "Proc"
      end

      it "a top-level local holding a lambda is a real local, not a global —\
          a same-named def afterward does not collide with it" do
        # If this were still Op::SetGlobal/Op::GetGlobal under the
        # hood, `def greet; \"method\"; end` afterward would silently
        # overwrite the SAME @globals slot the local used. Proven
        # behaviorally (return different, distinguishable values from
        # each) rather than via `.class`/`.proc?` from INSIDE the
        # script — deliberately, since those are covered by the
        # dedicated Proc spec instead and this spec isn't about them.
        src = <<-RUBY
        greet = ->() { "lambda" }
        def greet; "method"; end
        greet()
        RUBY
        eval(src).as_string.should eq "method"
      end

      it "reassigning a local after a same-named def still reads back the local, not the method" do
        # See the .robject?/rclass.name note on the "does NOT
        # auto-invoke" spec above — same Piece C reasoning applies here.
        src = <<-RUBY
        def greet; "method"; end
        greet = ->() { "lambda" }
        greet
        RUBY
        result = eval(src)
        result.robject?.should be_true
        result.as_robject.rclass.name.should eq "Proc"
      end

      # Regression coverage for the bug noted in the 2026-07-14
      # handoff: native functions live in the interpreter's native
      # table, not in @globals, so a bare reference used to miss the
      # ScriptProc check entirely and fall through to "push nil"
      # instead of ever calling the native fn. GetGlobal now routes
      # any non-data-global bare identifier through the same
      # dispatch_call path a real `name()` call uses, which checks
      # natives first.
      it "calls a native function when referenced bare (no parens)" do
        interp, _ = make_interp
        interp.define_native("read_input") { |_| Value.string("hello") }
        interp.eval(%("hello, " + read_input)).as_string.should eq "hello, hello"
      end

      it "still calls a native function normally when parens are used" do
        interp, _ = make_interp
        interp.define_native("read_input") { |_| Value.string("hello") }
        interp.eval(%("hello, " + read_input())).as_string.should eq "hello, hello"
      end

      # The other half of the same bug: an identifier that resolves
      # to nothing at all (no local, no native, no global proc/value,
      # no builtin) used to silently push nil via `gval || Value.nil_value`
      # instead of raising — unlike real Ruby, which raises on first
      # use of an undefined bare identifier. dispatch_call's existing
      # "unknown method" fallback now backs GetGlobal too, tagged as
      # NameError (script-catchable, since NameError < StandardError).
      it "raises NameError for a truly undefined bare identifier" do
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `totally_unknown`/) do
          eval("totally_unknown")
        end
      end

      it "raises NameError for an undefined identifier referenced inside a method body" do
        src = <<-RUBY
        def test
          unknown
        end
        test
        RUBY
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `unknown`/) do
          eval(src)
        end
      end

      it "is catchable via a script-level rescue, since NameError < StandardError" do
        src = <<-RUBY
        begin
          totally_unknown
        rescue => e
          e.message
        end
        RUBY
        # `e.message` is the diagnostic's summary and nothing else: the
        # code, the why, and the help stay out of the object a script
        # rescues, so this asserts the script-visible wording exactly.
        eval(src).as_string.should eq "undefined method or variable `totally_unknown`"
      end

      it "tags the raised error object as NameError specifically" do
        interp, _ = make_interp
        src = <<-RUBY
        begin
          totally_unknown
        rescue => e
          e.class.to_s
        end
        RUBY
        interp.eval(src).as_string.should contain "NameError"
      end

      it "x += 1 with no prior x raises, matching real Ruby's NameError " \
         "for a first-ever compound assignment" do
        # OpAssign compiles as `x = x + 1` — the READ half (x's
        # current value) runs before the WRITE half (which is what
        # defines x as a local on first sight — see emit_store).
        # With no earlier plain `x = ...` anywhere in scope, the read
        # genuinely has nothing to resolve to yet, same as real Ruby:
        # `x += 1` alone raises NameError, it does not silently
        # default x to 0/nil first.
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `x`/) do
          eval("x += 1")
        end
      end

      it "x += 1 works once x has a prior plain assignment earlier in scope" do
        eval("x = 0\nx += 1").as_int.should eq 1
      end
    end
  end
end
