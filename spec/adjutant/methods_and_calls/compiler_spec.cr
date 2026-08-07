require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "def" do
      it "compiles a def as MakeProc + DefMethod at top level, same as inside a class body" do
        # Previously SetGlobal at top level, a special case — piece B
        # (2026-07-16) unified this: self at top level is `main`, a
        # real RubyObject of class Object, so Op::DefMethod's uniform
        # "def always targets self's class" rule applies everywhere
        # now, no more @class_depth branch/top-level special case.
        o = ops("def greet()\nend")
        o.should contain(Op::MakeProc)
        o.should contain(Op::DefMethod)
        o.should_not contain(Op::SetGlobal)
      end

      it "compiles a def inside a class as DefMethod" do
        o = ops("class Foo\ndef bar\nend\nend")
        o.should contain(Op::DefMethod)
      end

      # Moved here from spec/scripts/block_param_capture.rb (2026-07-27)
      # — same reason as the keyword-argument call-site spec in
      # methods_and_calls/parser_spec.cr: test_runner's assert framework
      # can't intercept a CompileError either (same file-level, parse/
      # compile-before-any-execution blast radius as a ParseError) —
      # expect_raises directly against the compiler is the only way to
      # actually assert on this. `&blk` capture is a deliberate scope
      # decision (see UNSUPPORTED.md, U001) — this confirms it's rejected
      # immediately
      # at compile time now, not left to silently bind nothing.
      it "rejects &blk param capture at compile time" do
        expect_raises(CompileError, /block parameter capture/) do
          compile("def foo(&blk)\nend")
        end
      end

      it "carries a U001 diagnostic spanning the whole `&blk`" do
        # Asserting on the CODE rather than the prose: the code is the
        # stable identity, so rewording the message can't break this,
        # and the span is what a caret row is drawn from.
        error = expect_raises(CompileError) do
          compile("def foo(&blk)\nend")
        end
        diag = error.diagnostic
        diag.should_not be_nil
        diag = diag.not_nil!
        diag.code.should eq("U001")
        span = diag.primary.not_nil!
        span.line.should eq(1)
        # Column 9 is the `&`, not the name — parse_param records the
        # position before consuming the sigil.
        span.column.should eq(9)
        span.length.should eq(4)
        diag.data["method"].should eq("foo")
      end

      # UNSUPPORTED.md, U017: every operator-token method name except
      # `<=>` is rejected at compile time — real Ruby operator
      # overloading Adjutant deliberately doesn't support, since every
      # one of these compiles to a fixed opcode that never consults a
      # class's method table. Found via a concrete example script
      # defining X#<=/X#== that parsed cleanly and then silently
      # evaluated both comparisons wrong, with no error anywhere —
      # exactly the trap this guard exists to close.
      it "rejects def == at compile time" do
        expect_raises(CompileError, /cannot be redefined as a method/) do
          compile("class X\ndef ==(o)\nend\nend")
        end
      end

      it "rejects every overloadable operator name" do
        %w(== < <= > >= + - * / % & | ^ << >>).each do |op|
          expect_raises(CompileError) do
            compile("class X\ndef #{op}(o)\nend\nend")
          end
        end
      end

      it "carries a U017 diagnostic naming the operator, caret on `def`" do
        error = expect_raises(CompileError) do
          compile("class X\ndef ==(o)\nend\nend")
        end
        diag = error.diagnostic
        diag.should_not be_nil
        diag = diag.not_nil!
        diag.code.should eq("U017")
        span = diag.primary.not_nil!
        span.line.should eq(2)
        span.column.should eq(1)
        span.length.should eq(3)
        diag.data["operator"].should eq("==")
      end

      it "does NOT reject <=> — the one deliberate exception" do
        o = ops("class X\ndef <=>(o)\nend\nend")
        o.should contain(Op::DefMethod)
      end

      it "does not reject an ordinary comparison method with a different name" do
        # Regression check: the guard matches on exact operator names
        # only — a same-shaped but differently-named method (the
        # UNSUPPORTED.md-recommended workaround for ==) is untouched.
        o = ops("class X\ndef eql_value?(o)\nend\nend")
        o.should contain(Op::DefMethod)
      end

      it "does not reject an ordinary block-consuming def that uses yield" do
        # Regression check for the guard above — yield doesn't declare
        # &blk as a param at all, so it must be completely unaffected.
        o = ops("def foo\nyield 1\nend")
        o.should contain(Op::DefMethod)
      end

      # Moved/expanded here from spec/scripts/singleton_instance_methods.rb
      # (2026-07-27) — same reason as the &blk specs above: the guard
      # this file originally verified moved from a runtime check (only
      # `def self.foo`, only catchable via assert_raise during
      # execution) to a compile-time one covering BOTH `def self.foo`
      # AND plain `def foo` nested inside another method's body — see
      # compile_def's own comment for the full trace, including how the
      # person's own follow-up test script (`X5`/`nested`) proved the
      # original runtime-only, receiver-specific guard was incomplete:
      # a PLAIN `def` nested the same way was never caught at all, and
      # silently added a real instance method to the whole class,
      # visible to every other instance including ones constructed
      # after the fact.
      it "rejects def self.foo nested inside another method's body" do
        expect_raises(CompileError, /inside another method's body/) do
          compile("class A\ndef test\ndef self.hello\nend\nend\nend")
        end
      end

      it "rejects a plain def (no self.) nested inside another method's body" do
        # The shape the person's own X5/nested script exposed — this is
        # the one the ORIGINAL runtime-only guard never caught at all.
        expect_raises(CompileError, /inside another method's body/) do
          compile("class A\ndef test\ndef nested\nend\nend\nend")
        end
      end

      it "rejects a nested def even without an enclosing class (top-level def inside a def)" do
        expect_raises(CompileError, /inside another method's body/) do
          compile("def outer\ndef inner\nend\nend")
        end
      end

      it "rejects a def nested inside a lambda body" do
        expect_raises(CompileError, /inside another method's body/) do
          compile("f = ->() { def inner\nend }")
        end
      end

      it "names what the unassignable target actually was" do
        # AST class names (`Call`, `IntLiteral`) mean nothing to a script
        # author, so the diagnostic renders what they wrote.
        error = expect_raises(CompileError) do
          compile("foo() = 1")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("C001")
        diag.data["target"].should eq("a method call")
        # Was hardcoded to column 0 before the migration, which is not a
        # column any source position can have.
        diag.primary.not_nil!.column.not_nil!.should be > 0
      end

      it "rejects redo outside any loop as C002" do
        error = expect_raises(CompileError) do
          compile("redo")
        end
        error.diagnostic.not_nil!.code.should eq("C002")
      end

      it "reports the nesting limit, and its actual value, as L001" do
        # A limit rather than a fault: the script is valid, just too
        # deeply nested. The limit is interpolated so the message can't
        # drift from the constant.
        source = String.build do |io|
          17.times { |i| io << "while x#{i}\n" }
          17.times { io << "end\n" }
        end
        error = expect_raises(CompileError) do
          compile(source)
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("L001")
        diag.data["limit"].should eq("16")
      end

      it "carries a U004 diagnostic naming how the def was written" do
        # Asserting on the code, not the prose — the code is the stable
        # identity, so rewording the catalog can't break this.
        error = expect_raises(CompileError) do
          compile("class A\ndef test\ndef nested\nend\nend\nend")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("U004")
        diag.data["definition"].should eq("def nested")
        # Line 3 is the inner def; the column is the `def` keyword,
        # since parse_def records its position before consuming it.
        span = diag.primary.not_nil!
        span.line.should eq(3)
        span.column.should eq(1)
        span.length.should eq(3)
      end

      it "reports the def self.foo shape distinctly from a plain def" do
        # Both shapes hit the same guard, so the diagnostic has to
        # reconstruct which one was actually written — the compiler
        # has no access to the source text to slice it out of.
        error = expect_raises(CompileError) do
          compile("class A\ndef test\ndef self.nested\nend\nend\nend")
        end
        error.diagnostic.not_nil!.data["definition"].should eq("def self.nested")
      end

      it "still allows an ordinary def directly inside a class body" do
        # Regression check — the overwhelmingly common case must stay
        # completely unaffected.
        o = ops("class A\ndef test\nend\nend")
        o.should contain(Op::DefMethod)
      end

      it "still allows an ordinary top-level def self.foo (self == main)" do
        # Regression check — main's own singleton-style methods (the
        # one well-supported RubyObject-self case) are unaffected;
        # @def_depth is 0 here since this def isn't nested in anything.
        o = ops("def self.greet\nend")
        o.should contain(Op::DefSingleton)
      end
    end

    # Unit-level coverage for the 2026-08-03 argument-binding fix
    # (SCOPE.md's Must Fix — defaults/splats half; keywords remain
    # separate). spec/scripts/language/default_params.rb and
    # splat_params.rb already cover this end-to-end (real values, real
    # execution); these specs instead pin the actual BYTECODE
    # Compiler#emit_default_prologue produces, the same level every
    # other describe block in this file tests at — so a future
    # refactor that changes the shape (not just the outcome) of the
    # prologue gets caught here, closer to the change, rather than
    # only surfacing as a script-level behavior diff.
    describe "default-parameter prologue" do
      it "emits no prologue at all for a def with only required params" do
        # Regression check — the overwhelmingly common case (no
        # defaults) must not pay for or contain any of this machinery.
        o = def_proc_chunk("def add(a, b)\na + b\nend").code.map(&.op)
        o.should_not contain(Op::GetArgc)
      end

      it "emits GetArgc/Gte/JumpIfTrue guarding the default expression for one default param" do
        o = def_proc_chunk("def greet(name = \"world\")\nname\nend").code.map(&.op)
        o.first(4).should eq [Op::GetArgc, Op::Const, Op::Gte, Op::JumpIfTrue]
      end

      it "stores the applied default to the param's own slot and discards the leftover value" do
        # SetLocal (slot 0 — the only param) then Pop, matching the
        # same "expression compiled as a statement" shape used
        # elsewhere in this file (compile_body's own Pop-between-
        # statements), not left on the stack to corrupt whatever the
        # body pushes next.
        code = def_proc_chunk("def greet(name = \"world\")\nname\nend").code
        set_local = code.find { |inst| inst.op == Op::SetLocal }.not_nil!
        set_local.c.should eq 0_u32
        idx = code.index(set_local).not_nil!
        code[idx + 1].op.should eq Op::Pop
      end

      it "compares argc against slot+1 (1-based count vs 0-based slot), not the bare slot index" do
        # b is slot 1; supplied exactly when argc >= 2, not >= 1 — off
        # by one here would make `add(5, 10)` (2 args) incorrectly
        # skip a default it shouldn't need, or `add(5)` (1 arg)
        # incorrectly apply one it should.
        chunk = def_proc_chunk("def add(a, b = 10)\na + b\nend")
        const_idx = chunk.code[1].c # the Const right after GetArgc
        chunk.consts[const_idx].as_int.should eq 2_i64
      end

      it "emits one independent guarded block per default param, in declared order" do
        chunk = def_proc_chunk("def pair(a = 1, b = 2)\n[a, b]\nend")
        o = chunk.code.map(&.op)
        # Two full GetArgc...JumpIfTrue guards, not one shared check —
        # each default is independently omittable (pair(1) leaves only
        # b defaulted).
        o.count(Op::GetArgc).should eq 2
        o.count(Op::JumpIfTrue).should eq 2
        # First guard's Const is 1 (slot 0 + 1), second is 2 (slot 1 + 1).
        first_const_idx = chunk.code[1].c
        chunk.consts[first_const_idx].as_int.should eq 1_i64
      end

      it "compiles a default expression referencing an earlier param" do
        # def add(a, b = a + 1) — the applied-default branch just
        # compiles `a + 1` via the ordinary compile_node path, so it
        # should contain a plain GetLocal (resolving `a`) same as any
        # other expression referencing a param would.
        o = def_proc_chunk("def add(a, b = a + 1)\nb\nend").code.map(&.op)
        o.should contain(Op::GetLocal)
      end

      it "does NOT emit a default-value guard for a splat param" do
        # Splat collection happens in VM#bind_args (pure Array
        # slicing, nothing to evaluate) — the compiler has nothing to
        # do for it, so no GetArgc guard should exist at all here.
        o = def_proc_chunk("def sum(*args)\nargs\nend").code.map(&.op)
        o.should_not contain(Op::GetArgc)
      end

      it "does NOT emit a default-value guard for a kwarg param, even though it has a default" do
        # The fix the person's review caught before it shipped: a
        # kwarg param's `default` must stay unapplied here (deferred
        # to real keyword-argument support — see SCOPE.md's Must
        # Fix), even though Param#default is set for it exactly like
        # an ordinary positional default would be.
        o = def_proc_chunk("def greet(name: \"world\")\nname\nend").code.map(&.op)
        o.should_not contain(Op::GetArgc)
      end

      it "emits the prologue for a lambda's default params too, not just def" do
        o = def_proc_chunk("f = ->(x = 5) { x }").code.map(&.op)
        o.first(4).should eq [Op::GetArgc, Op::Const, Op::Gte, Op::JumpIfTrue]
      end

      it "emits the prologue for a call-site block literal's default params too" do
        o = def_proc_chunk("[1].each { |x = 9| x }").code.map(&.op)
        o.first(4).should eq [Op::GetArgc, Op::Const, Op::Gte, Op::JumpIfTrue]
      end

      it "emits no prologue for a for-loop's desugared block (synthetic params, never have defaults)" do
        o = def_proc_chunk("for x in [1, 2, 3]\nx\nend").code.map(&.op)
        o.should_not contain(Op::GetArgc)
      end
    end

    describe "calls" do
      it "compiles a bare call with SetBlock and Call" do
        o = ops("puts(42)")
        o.should contain(Op::SetBlock)
        o.should contain(Op::Call)
      end

      it "compiles a receiver call" do
        o = ops("foo.bar")
        o.should contain(Op::GetGlobal)
        o.should contain(Op::Call)
      end

      it "compiles index access with GetIndex" do
        # `arr` must be a known local first, or `arr[0]` parses as a
        # bare call (see methods_and_calls/parser_spec.cr's "identifier
        # vs. index disambiguation" describe block and parser.cr's
        # @local_scopes comment) — matches real Ruby's own parse-time
        # rule, fixed 2026-07-21.
        ops("arr = []\narr[0]").should contain(Op::GetIndex)
      end

      it "compiles index assignment with SetIndex" do
        ops("arr = []\narr[0] = 1").should contain(Op::SetIndex)
      end
    end

    describe "yield" do
      it "compiles yield with Yield opcode" do
        # yield is in the method body chunk; outer chunk just registers the def
        chunk = compile("def f\nyield 1\nend")
        chunk.code.map(&.op).should contain(Op::DefMethod)
      end
    end
  end
end
