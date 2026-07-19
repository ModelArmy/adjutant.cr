require "../spec_helper"

module Adjutant
  describe Interpreter do
    describe "literals" do
      it "evaluates nil" do
        eval("nil").null?.should be_true
      end

      it "evaluates true" do
        eval("true").as_bool.should be_true
      end

      it "evaluates false" do
        eval("false").as_bool.should be_false
      end

      it "evaluates an integer" do
        eval("42").as_int.should eq 42_i64
      end

      it "evaluates a float" do
        eval("3.14").as_float.should be_close(3.14, 1e-10)
      end

      it "evaluates a string" do
        eval(%("hello")).as_string.should eq "hello"
      end

      it "evaluates a symbol" do
        v = eval(":ok")
        v.symbol?.should be_true
        v.as_sym.name.should eq "ok"
      end

      it "evaluates an array literal" do
        v = eval("[1, 2, 3]")
        v.array?.should be_true
        v.as_array.size.should eq 3
      end

      it "evaluates a hash literal" do
        v = eval(%({ "a" => 1 }))
        v.hash?.should be_true
        v.as_hash.size.should eq 1
      end
    end

    describe "arithmetic" do
      it "adds integers" do
        eval("1 + 2").as_int.should eq 3_i64
      end

      it "subtracts integers" do
        eval("5 - 3").as_int.should eq 2_i64
      end

      it "multiplies integers" do
        eval("3 * 4").as_int.should eq 12_i64
      end

      it "divides integers (floor)" do
        eval("7 / 2").as_int.should eq 3_i64
      end

      it "computes modulo" do
        eval("7 % 3").as_int.should eq 1_i64
      end

      it "adds floats" do
        eval("1.5 + 2.5").as_float.should be_close(4.0, 1e-10)
      end

      it "promotes int+float to float" do
        eval("1 + 2.5").as_float.should be_close(3.5, 1e-10)
      end

      it "concatenates strings with +" do
        eval(%("hello" + " world")).as_string.should eq "hello world"
      end

      it "negates an integer" do
        eval("-7").as_int.should eq -7_i64
      end

      it "raises on divide by zero" do
        expect_raises(RuntimeError) { eval("1 / 0") }
      end
    end

    describe "comparison" do
      it "compares integers with ==" do
        eval("1 == 1").as_bool.should be_true
        eval("1 == 2").as_bool.should be_false
      end

      it "compares integers with !=" do
        eval("1 != 2").as_bool.should be_true
      end

      it "compares integers with <" do
        eval("1 < 2").as_bool.should be_true
        eval("2 < 1").as_bool.should be_false
      end

      it "compares integers with <=" do
        eval("2 <= 2").as_bool.should be_true
      end

      it "compares integers with >" do
        eval("3 > 2").as_bool.should be_true
      end

      it "compares nil == nil" do
        eval("nil == nil").as_bool.should be_true
      end

      it "compares symbols by identity" do
        eval(":foo == :foo").as_bool.should be_true
        eval(":foo == :bar").as_bool.should be_false
      end
    end

    describe "boolean logic" do
      it "short-circuits ||" do
        eval("true || false").as_bool.should be_true
        eval("false || true").as_bool.should be_true
      end

      it "short-circuits &&" do
        eval("true && false").as_bool.should be_false
        eval("true && true").as_bool.should be_true
      end

      it "negates with !" do
        eval("!true").as_bool.should be_false
        eval("!false").as_bool.should be_true
        eval("!nil").as_bool.should be_true
      end
    end

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
    end

    describe "string interpolation" do
      it "interpolates an integer" do
        eval(%("value: \#{42}")).as_string.should eq "value: 42"
      end

      it "interpolates a variable" do
        eval(%(x = "world"\n"hello \#{x}")).as_string.should eq "hello world"
      end
    end

    describe "indexing" do
      it "indexes into an array" do
        eval("[10, 20, 30][1]").as_int.should eq 20_i64
      end

      it "indexes with negative index" do
        eval("[1, 2, 3][-1]").as_int.should eq 3_i64
      end

      it "assigns to an array index" do
        eval("a = [1, 2, 3]\na[0] = 99\na[0]").as_int.should eq 99_i64
      end

      it "indexes into a hash" do
        eval(%({ "k" => 42 }["k"])).as_int.should eq 42_i64
      end
    end

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
    end

    describe "effect handler" do
      it "captures puts output" do
        interp, ef = make_interp
        interp.eval(%{puts("hello")})
        ef.stdout.should eq "hello\n"
      end

      it "captures multiple puts calls" do
        interp, ef = make_interp
        interp.eval("puts(1)\nputs(2)")
        ef.stdout_log.size.should eq 2
      end

      it "captures print without newline" do
        interp, ef = make_interp
        interp.eval(%{print("hi")})
        ef.stdout.should eq "hi"
      end
    end

    describe "execution limits" do
      it "raises when instruction limit exceeded" do
        limits = ExecutionLimits.new(instruction_limit: 5_u64)
        interp, _ = make_interp(limits)
        expect_raises(RuntimeError, /instruction limit/) do
          interp.eval("x = 0\nwhile true\nx += 1\nend")
        end
      end

      it "stores the call depth limit" do
        # Full call depth enforcement requires wired def/call (Phase 6).
        # Verify the limit is stored and accessible.
        limits = ExecutionLimits.new(call_depth_limit: 3)
        interp, _ = make_interp(limits)
        interp.limits.call_depth_limit.should eq 3
      end
    end

    describe "require via VFS" do
      it "loads a script file from the VFS and its def is callable afterward" do
        # A required file's DEF should be visible afterward, same as
        # real Ruby (require executes the file and its method/class/
        # constant definitions persist in the requiring context). A
        # required file's own top-level LOCAL variables should NOT
        # persist — require's VFS fallback runs the file via a
        # genuinely separate eval call (see
        # Interpreter#require_module), and a top-level local is now
        # correctly scoped to its own eval call (see the 2026-07-15
        # scoping fix) — matching real Ruby, where a required file's
        # locals were never visible to the requiring context either.
        interp, ef = make_interp
        ef.add_file("greet.rb", %(def greeting; "hello from vfs"; end))
        interp.eval(%(require "greet.rb"))
        interp.eval("greeting").as_string.should eq "hello from vfs"
      end

      it "does NOT leak a required file's own top-level local variables" do
        interp, ef = make_interp
        ef.add_file("greet.rb", %(x = "hello from vfs"))
        interp.eval(%(require "greet.rb"))
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: x/) do
          interp.eval("x")
        end
      end

      it "raises when file not found" do
        interp, _ = make_interp
        expect_raises(RuntimeError, /cannot load/) do
          interp.eval(%(require "missing.rb"))
        end
      end

      it "loads a registered script module" do
        interp, _ = make_interp
        interp.modules.register("agent/math") do |i|
          i.define_native("double") { |args| Value.int(args.first.as_int * 2) }
        end
        interp.eval(%(require "agent/math"\ndouble(5))).as_int.should eq 10_i64
      end

      it "loads each module only once" do
        count = 0
        interp, _ = make_interp
        interp.modules.register("once") { |_| count += 1 }
        interp.eval(%(require "once"\nrequire "once"))
        count.should eq 1
      end
    end

    describe "native functions" do
      it "calls a native function registered via define_native" do
        interp, _ = make_interp
        interp.define_native("double") { |args| Value.int(args.first.as_int * 2) }
        interp.eval("double(21)").as_int.should eq 42_i64
      end

      it "calls a native function exposed via a script module" do
        interp, _ = make_interp
        interp.modules.register("mylib") do |i|
          i.define_native("triple") { |args| Value.int(args.first.as_int * 3) }
        end
        interp.eval("require \"mylib\"\ntriple(7)").as_int.should eq 21_i64
      end
    end

    describe "shared symbol table across evals" do
      it "does NOT retain a plain top-level variable across separate evals" do
        # This spec used to assert the opposite — the exact bug the
        # 2026-07-15 scoping fix corrects. Sharing one SymbolTable
        # across eval calls (so "x" always interns to the same
        # integer ID — see the sibling spec below) does NOT imply
        # variable VALUES persist across calls; those are two
        # independent things. A top-level local is scoped to its own
        # CompilerScope/Frame, fresh every eval call, matching real
        # Ruby (nothing links two separately-run scripts' locals just
        # because they happen to share a process/interpreter).
        interp, _ = make_interp
        interp.eval("x = 10")
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: x/) do
          interp.eval("x + 5")
        end
      end

      it "DOES retain a top-level def across separate evals" do
        # Unlike plain variables, a def genuinely should persist —
        # this is require's whole point (see the VFS require specs
        # above) and matches real Ruby (a required file's methods
        # remain callable afterward).
        interp, _ = make_interp
        interp.eval("def ten; 10; end")
        interp.eval("ten + 5").as_int.should eq 15_i64
      end

      it "shares symbol IDs across compilations" do
        interp, _ = make_interp
        interp.eval(":shared")
        id1 = interp.symbols.intern("shared").value
        interp.eval(":shared")
        id2 = interp.symbols.intern("shared").value
        id1.should eq id2
      end
    end

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

    describe "realistic programs" do
      it "computes fibonacci iteratively" do
        src = <<-RUBY
          a = 0
          b = 1
          i = 0
          while i < 10
            tmp = a + b
            a = b
            b = tmp
            i += 1
          end
          a
        RUBY
        # fib(10) = 55
        eval(src).as_int.should eq 55_i64
      end

      it "sums an array" do
        src = <<-RUBY
        arr = [1, 2, 3, 4, 5]
        sum = 0
        i = 0
        while i < 5
          sum += arr[i]
          i += 1
        end
        sum
        RUBY
        eval(src).as_int.should eq 15_i64
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: totally_unknown/) do
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: unknown/) do
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
        eval(src).as_string.should eq "undefined method or variable: totally_unknown"
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: x/) do
          eval("x += 1")
        end
      end

      it "x += 1 works once x has a prior plain assignment earlier in scope" do
        eval("x = 0\nx += 1").as_int.should eq 1
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

    # Range: a real RubyObject (@min/@max/@exclusive ivars) backing
    # `1..5`/`1...5` literals, replacing the earlier
    # `[start, end, exclusive_flag]` LabeledArray stand-in noted in
    # the 2026-07-14 handoff. #each is implemented via #succ (see
    # builtins/range.cr and Integer#succ in builtins/integer.cr),
    # which is why Integer#succ is exercised indirectly by every
    # each/for-loop-over-a-Range spec here, not just directly.
    describe "Range" do
      it "is a real RubyObject, not an Array" do
        interp, _ = make_interp
        src = <<-RUBY
        r = 1..5
        [r.class.to_s, r.is_a?(Array)]
        RUBY
        result = interp.eval(src).as_array
        result[0].as_string.should eq "Range"
        result[1].as_bool.should be_false
      end

      it "exposes min/max/first/last" do
        src = <<-RUBY
        r = 2..7
        [r.min, r.max, r.first, r.last]
        RUBY
        result = eval(src).as_array.map(&.as_int)
        result.should eq [2, 7, 2, 7]
      end

      it "exclusive? is false for .. and true for ..." do
        src = <<-RUBY
        [(1..5).exclusive?, (1...5).exclusive?]
        RUBY
        result = eval(src).as_array.map(&.as_bool)
        result.should eq [false, true]
      end

      it "Integer#succ advances by one" do
        eval("5.succ").as_int.should eq 6
      end

      it "each yields every value, inclusive of max for .." do
        src = <<-RUBY
        seen = []
        (1..4).each { |n| seen << n }
        seen
        RUBY
        eval(src).as_array.map(&.as_int).should eq [1, 2, 3, 4]
      end

      it "each excludes max for ..." do
        src = <<-RUBY
        seen = []
        (1...4).each { |n| seen << n }
        seen
        RUBY
        eval(src).as_array.map(&.as_int).should eq [1, 2, 3]
      end

      it "each on an empty range (min > max) yields nothing" do
        src = <<-RUBY
        seen = []
        (5..1).each { |n| seen << n }
        seen
        RUBY
        eval(src).as_array.should be_empty
      end

      it "each returns the receiver, matching real Ruby" do
        src = <<-RUBY
        r = 1..3
        (r.each { |n| n }).equal?(r)
        RUBY
        eval(src).as_bool.should be_true
      end

      it "include? respects exclusivity at the boundary" do
        src = <<-RUBY
        [
          (1..5).include?(5),
          (1...5).include?(5),
          (1..5).include?(0),
          (1..5).include?(3),
        ]
        RUBY
        result = eval(src).as_array.map(&.as_bool)
        result.should eq [true, false, false, true]
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

    # Op::SetConstant hardening, added 2026-07-18 ahead of Piece D (see
    # SCOPE.md): real Ruby only WARNS on constant reassignment (still
    # permits it); Adjutant deliberately makes it a hard error, so a
    # constant-valued Lambda passed as a call argument can be trusted
    # to be staticaly resolvable by RiskWalker — nothing else in the
    # same script could have quietly reassigned it first. Covers both
    # branches of Op::SetConstant's target-vs-@globals split: a
    # top-level `FOO = 1` (target is nil — main is a RubyObject, not a
    # RubyClass, and top-level code has no lexical_scope) and a
    # constant defined inside a class/module body (target is that
    # RubyClass, via target.constants) both need the same guard; this
    # was a real bug in an earlier draft of the fix (the guard was
    # first written narrowly, only catching @globals-routed
    # reassignment for rclass-valued — i.e. class-name — constants,
    # which would have silently let a plain top-level `FOO = 1; FOO =
    # 2` back through).
    describe "constants" do
      it "a plain top-level constant assigned once works normally" do
        eval("FOO = 1\nFOO").as_int.should eq 1
      end

      it "reassigning a plain top-level constant raises" do
        expect_raises(RuntimeError, /already initialized/) do
          eval("FOO = 1\nFOO = 2")
        end
      end

      it "reassigning a constant defined inside a class body raises" do
        expect_raises(RuntimeError, /already initialized/) do
          eval(<<-RUBY)
          class Foo
            BAR = 1
            BAR = 2
          end
          RUBY
        end
      end

      it "the same constant name in two DIFFERENT classes does not collide" do
        # target.constants is per-RubyClass — Foo::BAR and Baz::BAR are
        # unrelated slots, confirming the guard checks the right Hash,
        # not some shared/global one.
        result = eval(<<-RUBY)
        class Foo
          BAR = 1
        end
        class Baz
          BAR = 2
        end
        [Foo::BAR, Baz::BAR]
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2]
      end

      it "defining a class once works normally" do
        eval(<<-RUBY).as_int.should eq 5
        class Foo
          def five; 5; end
        end
        Foo.new.five
        RUBY
      end

      it "reopening (redefining) a class raises rather than silently discarding the first body" do
        # Previously: Op::MakeClass always allocated a fresh,
        # disconnected RubyClass and Op::SetConstant just overwrote the
        # constant slot — `five` from the first body was silently
        # lost, not a compile/runtime error. See SCOPE.md's "Class/
        # module reopening" Won't Fix entry for why real reopening
        # isn't being built instead.
        expect_raises(RuntimeError, /already initialized/) do
          eval(<<-RUBY)
          class Foo
            def five; 5; end
          end
          class Foo
            def six; 6; end
          end
          RUBY
        end
      end

      it "reopening a builtin class also raises, same policy" do
        # Builtin classes (Integer, String, Array, ...) are registered
        # into the same @globals constant space as script-defined ones
        # during Interpreter bootstrap (see
        # Interpreter#define_global_class) — so this is the SAME
        # SetConstant path and guard, not a special case. Real Ruby's
        # most common reopening use case (monkey-patching a builtin) is
        # therefore also a hard error now, consistent with the
        # deliberate Won't Fix decision, not an oversight.
        expect_raises(RuntimeError, /already initialized/) do
          eval(<<-RUBY)
          class String
            def shout; upcase; end
          end
          RUBY
        end
      end
    end
  end
end
