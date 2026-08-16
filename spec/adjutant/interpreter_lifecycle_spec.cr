require "../spec_helper"

module Adjutant
  describe Interpreter do
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

      # Step 2 of the to_s/inspect overridability work (see
      # object_spec.cr's own header comment and DEVELOPMENT.md for
      # the full plan) — puts/print/p now go through real dispatch
      # (render_to_s/render_inspect, vm.cr), the same fix Op::Concat
      # (string interpolation) already got in step 1.
      it "puts uses a script class's own `def to_s` override, not the generic default" do
        interp, ef = make_interp
        interp.eval(<<-RUBY)
        class A
          def to_s
            "custom!"
          end
        end
        puts(A.new)
        RUBY
        ef.stdout.should eq "custom!\n"
      end

      it "puts on a plain object with no override still prints #<ClassName>, unchanged" do
        interp, ef = make_interp
        interp.eval(<<-RUBY)
        class A
        end
        puts(A.new)
        RUBY
        ef.stdout.should eq "#<A>\n"
      end

      it "print uses a script class's own `def to_s` override too" do
        interp, ef = make_interp
        interp.eval(<<-RUBY)
        class A
          def to_s
            "custom!"
          end
        end
        print(A.new)
        RUBY
        ef.stdout.should eq "custom!"
      end

      it "puts fixes a real pre-existing bug: a Symbol argument no longer prints with a stray leading colon" do
        # The OLD exec_builtin code called `arg.as_sym.to_s`, which
        # (per Sym#to_s's own colon-inclusive quirk, symbol_table.cr)
        # printed `puts :sym` as `:sym`. Real Ruby's `puts :sym`
        # prints `sym`, no colon — matching what render_to_s (already
        # used by string interpolation since step 1) has always done.
        interp, ef = make_interp
        interp.eval("puts(:sym)")
        ef.stdout.should eq "sym\n"
      end

      it "puts on a Range now prints its real rendering, not the generic RubyObject fallback — fixed as a side effect of routing through real dispatch, same as interpolation's Range fix in step 1" do
        interp, ef = make_interp
        interp.eval("puts(1..3)")
        ef.stdout.should eq "1..3\n"
      end

      it "p uses a script class's own `def inspect` override" do
        interp, ef = make_interp
        interp.eval(<<-RUBY)
        class A
          def inspect
            "custom inspect!"
          end
        end
        p(A.new)
        RUBY
        ef.stdout.should eq "custom inspect!\n"
      end

      it "p on a plain object with no override falls back to Object's own default #inspect (ivar-listing, from step 1) — not just #<ClassName>" do
        interp, ef = make_interp
        interp.eval(<<-RUBY)
        class A
          def initialize
            @x = 1
          end
        end
        p(A.new)
        RUBY
        ef.stdout.should eq "#<A @x=1>\n"
      end

      it "p still returns its single argument, unaffected by the render_inspect wiring" do
        interp, _ = make_interp
        interp.eval("p(5)").as_int.should eq 5_i64
      end

      it "p on a String still quotes it, via the existing Value#inspect fast path" do
        interp, ef = make_interp
        interp.eval(%{p("hi")})
        ef.stdout.should eq %{"hi"\n}
      end

      it "p on a Symbol still keeps the leading colon (unlike puts) — inspect and to_s deliberately differ here" do
        interp, ef = make_interp
        interp.eval("p(:sym)")
        ef.stdout.should eq ":sym\n"
      end
    end

    describe "execution limits" do
      it "raises when instruction limit exceeded" do
        limits = ExecutionLimits.new(instruction_limit: 5_u64)
        interp, _ = make_interp(limits)
        error = expect_raises(RuntimeError, /instruction limit/) do
          interp.eval("x = 0\nwhile true\nx += 1\nend")
        end
        # An L code, not an R: the script is not malformed, it just
        # exceeded a budget, and the reader's move differs accordingly.
        diag = error.diagnostic.not_nil!
        diag.code.should eq("L004")
        diag.data["limit"].should eq("5")
      end

      it "stores the call depth limit" do
        limits = ExecutionLimits.new(call_depth_limit: 3)
        interp, _ = make_interp(limits)
        interp.limits.call_depth_limit.should eq 3
      end

      it "enforces the call depth limit, reporting the configured value" do
        # The comment here used to say enforcement awaited wired
        # def/call. That landed, so this is testable now.
        limits = ExecutionLimits.new(call_depth_limit: 4)
        interp, _ = make_interp(limits)
        error = expect_raises(RuntimeError) do
          interp.eval("def down(n)\n  down(n + 1)\nend\ndown(0)")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("L002")
        diag.data["limit"].should eq("4")
      end

      it "tells the reader which limits a host can actually raise" do
        # L002 and L004 guard ExecutionLimits settings, so their help
        # can point at them. L003 guards a fixed constant and must not
        # imply a knob exists.
        ErrorCatalog["L002"].help.not_nil!.should contain("call_depth_limit")
        ErrorCatalog["L004"].help.not_nil!.should contain("instruction_limit")
        ErrorCatalog["L003"].help.not_nil!.should_not contain("limit`")
        ErrorCatalog["L003"].why.not_nil!.should contain("not a setting")
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

      # Regression for invoke_proc's non-Proc guard, added 2026-07-20
      # alongside invoke_proc itself (see README.md's NativeCallContext
      # table and vm.cr's invoke_proc comment). invoke_proc takes a
      # caller-supplied RubyObject — unlike invoke's ScriptProc, always
      # internally sourced from a trusted `blk` param — so a native
      # function author could plausibly pass the wrong RubyObject by
      # mistake (an ordinary instance, not a Proc). Without the guard
      # this would fail with a raw Crystal KeyError (missing __sproc
      # ivar) or TypeCastError, neither catchable as an
      # Adjutant::RuntimeError nor informative. This registers a
      # throwaway native function that deliberately misuses
      # invoke_proc on a plain object and asserts a proper, clear
      # RuntimeError instead.
      it "invoke_proc misuse surfaces as a clear error, attributed to the native layer" do
        # Two layers, and the nesting is unavoidable rather than merely
        # deliberate: `invoke_proc` is only reachable through the
        # NativeCallContext handed to a native function, so its H004 is
        # ALWAYS raised inside a native call and always caught by
        # call_native's rescue. It therefore surfaces as N001 carrying
        # H004 as its message — which is the useful shape anyway, naming
        # both the function that failed and why.
        interp, _ = make_interp
        interp.define_native("misuse_invoke_proc") do |args, _blk, ncc|
          ncc.invoke_proc(args.first.as_robject, [] of Value)
        end
        error = expect_raises(Adjutant::RuntimeError) do
          interp.eval(<<-RUBY)
            class Plain
            end
            misuse_invoke_proc(Plain.new)
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("N001")
        # The inner H004 is carried through as the native layer's own
        # message, so the actual cause stays visible.
        diag.data["message"].should contain("H004")
        diag.data["message"].should contain("Plain")
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `x`/) do
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
  end
end
