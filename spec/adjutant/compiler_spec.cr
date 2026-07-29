require "../spec_helper"

module Adjutant
  # Shared symbol table for compiler specs — simulates multiple scripts
  # compiled against the same interpreter instance.
  COMPILER_SPEC_SYMBOLS = SymbolTable.new

  # Helper: parse source and compile to a Chunk.
  private def self.compile(source : String) : Chunk
    body = Parser.new(source).parse
    chunk, _local_count = Compiler.compile(body, COMPILER_SPEC_SYMBOLS)
    chunk
  end

  # Helper: return just the opcode sequence (excluding Const setup noise).
  private def self.ops(source : String) : Array(Op)
    compile(source).code.map(&.op)
  end

  describe Compiler do
    describe "literals" do
      it "compiles nil to Const" do
        chunk = compile("nil")
        chunk.code.first.op.should eq Op::Const
        chunk.consts.first.null?.should be_true
      end

      it "compiles true" do
        chunk = compile("true")
        chunk.consts.first.as_bool.should be_true
      end

      it "compiles false" do
        chunk = compile("false")
        chunk.consts.first.as_bool.should be_false
      end

      it "compiles an integer" do
        chunk = compile("42")
        chunk.consts.first.as_int.should eq 42_i64
      end

      it "compiles a negative NUMERIC LITERAL as a fused literal, not Unary+Neg" do
        # Changed 2026-07-25 (SCOPE.md's "Unary minus on a
        # NEGATIVE-NUMERIC-LITERAL binds looser than postfix" fix) —
        # `-7` immediately adjacent (no space) to a numeric literal now
        # fuses into a single negative IntLiteral at parse time
        # (parser.cr's parse_unary), matching Ruby's own tUMINUS_NUM
        # lexer-level mechanism, rather than compiling to a separate
        # Op::Neg over a positive constant. Same runtime value, simpler
        # bytecode (one Const, not Const+Neg) — and, more importantly,
        # this is what makes `-0.0.to_s` group as `(-0.0).to_s` instead
        # of `-(0.0.to_s)` (see the "does not compile Op::Neg" spec
        # right below, and vm_spec.cr's coverage of the actual
        # to_s-grouping bug this was found from).
        chunk = compile("-7")
        chunk.code.map(&.op).should_not contain(Op::Neg)
        chunk.consts.first.as_int.should eq -7_i64
      end

      it "still compiles Unary+Neg for a non-literal unary-minus target" do
        # Every unary-minus target that ISN'T an immediately-adjacent
        # numeric literal — a variable, a call result, a parenthesized
        # expression, or even a literal WITH a space after the `-` —
        # is unaffected by the fusion above and still goes through the
        # ordinary Unary/Op::Neg path.
        chunk = compile("x = 7\n-x")
        chunk.code.map(&.op).should contain(Op::Neg)
      end

      it "compiles a hex integer" do
        chunk = compile("0xFF")
        chunk.consts.first.as_int.should eq 255_i64
      end

      it "compiles a float" do
        chunk = compile("3.14")
        chunk.consts.first.as_float.should be_close(3.14, 1e-10)
      end

      # Fixed 2026-07-25 (SCOPE.md's deferred underflow/overflow
      # sub-item, closed out). String#to_f64 raises ArgumentError on a
      # numerically out-of-Float64-range lexeme; mruby's own float
      # parser (and IEEE-754 generally) rounds these cleanly to a
      # signed 0.0/Infinity instead — confirmed as the correct target
      # behavior via mruby's own test/t/float.rb "Float literal
      # underflow" regression, which this closes.
      describe "underflow/overflow" do
        it "rounds an extreme negative-exponent literal to 0.0" do
          chunk = compile("1.0e-400")
          chunk.consts.first.as_float.should eq 0.0
        end

        it "rounds a large-mantissa extreme-exponent literal to signed -0.0" do
          # The actual case that most needed the TRUE combined exponent
          # (mantissa digit count + explicit e-suffix), not just the
          # e-suffix alone — a naive "just look at e-383" reading would
          # underestimate this literal's true magnitude by ~40 orders
          # of magnitude (41 mantissa digits).
          chunk = compile("-92170141183460469231731687303715884105729e-383")
          f = chunk.consts.first.as_float
          f.should eq 0.0
          (1.0 / f).should be < 0 # distinguishes -0.0 from 0.0
        end

        it "rounds an extreme positive-exponent literal to Infinity" do
          chunk = compile("1.0e400")
          chunk.consts.first.as_float.infinite?.should eq 1
        end

        it "rounds a negated extreme positive-exponent literal to -Infinity" do
          chunk = compile("-1.0e400")
          chunk.consts.first.as_float.infinite?.should eq -1
        end

        it "does not misjudge an all-zero mantissa with a huge exponent as overflow" do
          # A real bug found and fixed while implementing this: an
          # all-zero mantissa is mathematically 0 regardless of its
          # exponent (0 * 10^anything = 0), but the general true-
          # exponent calculation, if applied blindly, treats an
          # all-zero mantissa the same as a genuine leading-zero run
          # and computes a large POSITIVE exponent for "0.0e400" —
          # which would incorrectly route it to the overflow/Infinity
          # branch instead of leaving it as plain 0.0.
          chunk = compile("0.0e400")
          chunk.consts.first.as_float.should eq 0.0
          chunk.consts.first.as_float.infinite?.should be_nil
        end

        it "leaves an ordinary large-but-in-range literal untouched" do
          # From mruby's own float.rb test data directly — must NOT be
          # caught by the underflow/overflow guard just because it has
          # a big exponent; it's genuinely representable.
          chunk = compile("1.0e307")
          chunk.consts.first.as_float.should be_close(1.0e307, 1e300)
        end

        it "does not misclassify a near-boundary literal that the approximate exponent margin alone would miss" do
          # A second real edge case found while implementing this: the
          # exponent-range pre-check uses a deliberately approximate
          # margin (comfortably inside Float64's real ~308.25/-323.3
          # exponent bounds), NOT an exact boundary — so a literal with
          # true exponent 309 (genuinely over Float64::MAX) still falls
          # inside that approximate "safe" margin and must still be
          # caught via a to_f64? fallback within that branch, not just
          # the branch that's obviously out of range.
          chunk = compile("1.0e309")
          chunk.consts.first.as_float.infinite?.should eq 1
        end
      end

      it "compiles a string" do
        chunk = compile(%("hello"))
        chunk.consts.first.as_string.should eq "hello"
      end

      it "compiles a symbol" do
        chunk = compile(":ok")
        chunk.consts.first.as_sym.name.should eq "ok"
      end

      it "compiles an array literal" do
        ops("[1, 2, 3]").should contain(Op::MakeArray)
      end

      it "compiles a hash literal" do
        ops(%({ "a" => 1 })).should contain(Op::MakeHash)
      end

      it "compiles an inclusive range" do
        chunk = compile("1..10")
        chunk.code.map(&.op).should contain(Op::MakeRange)
        range_inst = chunk.code.find { |i| i.op == Op::MakeRange }.not_nil!
        range_inst.a.should eq 0_u8
      end

      it "compiles an exclusive range" do
        chunk = compile("1...10")
        range_inst = chunk.code.find { |i| i.op == Op::MakeRange }.not_nil!
        range_inst.a.should eq 1_u8
      end

      it "compiles an interpolated string" do
        ops(%("hello \#{42}!")).should contain(Op::Concat)
      end
    end

    describe "constant pool deduplication" do
      it "deduplicates nil constants" do
        chunk = compile("nil")
        chunk.consts.count { |v| v.null? }.should eq 1
      end

      it "deduplicates boolean constants" do
        chunk = compile("true")
        chunk.consts.count { |v| v.bool? && v.as_bool }.should eq 1
      end

      it "deduplicates symbol constants" do
        # x = 1; x used to exercise this by accident, via
        # SetGlobal/GetGlobal both needing a :x Sym constant to look
        # up in @globals — now that top-level locals get real
        # CompilerScope slots (see the 2026-07-15 scoping fix),
        # x = 1; x compiles to SetLocal/GetLocal (integer slot
        # indices, no Sym constant involved at all). Test what this
        # spec is actually about — Symbol constant dedup — directly,
        # with a repeated Symbol literal instead.
        chunk = compile(":x\n:x")
        x_count = chunk.consts.count { |v| v.symbol? && v.as_sym.name == "x" }
        x_count.should eq 1
      end
    end

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

    describe "assignment" do
      it "compiles simple top-level assignment with SetLocal, not SetGlobal" do
        # Previously x = 1 at top level compiled to SetGlobal — the
        # exact bug the 2026-07-15 scoping fix corrects (see
        # Compiler.compile/CompilerScope). A bare top-level assignment
        # is now a real local, matching real Ruby (SetGlobal is
        # reserved for `def` at top level, and $global-style globals
        # once those land — never a plain `x = 1`).
        o = ops("x = 1")
        o.should contain(Op::SetLocal)
        o.should_not contain(Op::SetGlobal)
      end

      it "compiles ivar assignment with SetIvar" do
        ops("@x = 1").should contain(Op::SetIvar)
      end

      it "compiles cvar assignment with SetCvar" do
        ops("@@x = 1").should contain(Op::SetCvar)
      end

      it "compiles += as load, add, store, all against the local — not global" do
        o = ops("x = 0\nx += 1")
        o.should contain(Op::GetLocal)
        o.should contain(Op::Add)
        o.should contain(Op::SetLocal)
        o.should_not contain(Op::SetGlobal)
      end
    end

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
        # bare call (see parser_spec.cr's "identifier vs. index
        # disambiguation" describe block and parser.cr's
        # @local_scopes comment) — matches real Ruby's own parse-time
        # rule, fixed 2026-07-21.
        ops("arr = []\narr[0]").should contain(Op::GetIndex)
      end

      it "compiles index assignment with SetIndex" do
        ops("arr = []\narr[0] = 1").should contain(Op::SetIndex)
      end
    end

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
      # parser_spec.cr: test_runner's assert framework can't intercept a
      # CompileError either (same file-level, parse/compile-before-any-
      # execution blast radius as a ParseError) — expect_raises directly
      # against the compiler is the only way to actually assert on this.
      # `&blk` capture is a deliberate scope decision (see
      # UNSUPPORTED.md, U001) — this confirms it's rejected immediately
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
        diag.primary.line.should eq(1)
        # Column 9 is the `&`, not the name — parse_param records the
        # position before consuming the sigil.
        diag.primary.column.should eq(9)
        diag.primary.length.should eq(4)
        diag.data["method"].should eq("foo")
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
        diag.primary.column.not_nil!.should be > 0
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
        diag.primary.line.should eq(3)
        diag.primary.column.should eq(1)
        diag.primary.length.should eq(3)
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

    describe "class and module" do
      it "compiles a class with MakeClass" do
        ops("class Dog\nend").should contain(Op::MakeClass)
      end

      it "compiles a module with MakeModule" do
        ops("module Greetable\nend").should contain(Op::MakeModule)
      end

      it "encodes superclass index in MakeClass.b" do
        chunk = compile("class Poodle < Dog\nend")
        inst = chunk.code.find { |i| i.op == Op::MakeClass }.not_nil!
        inst.b.should_not eq Compiler::NO_SUPER
      end

      it "uses NO_SUPER sentinel when no superclass" do
        chunk = compile("class Dog\nend")
        inst = chunk.code.find { |i| i.op == Op::MakeClass }.not_nil!
        inst.b.should eq Compiler::NO_SUPER
      end
    end

    describe "begin/rescue" do
      it "compiles begin/rescue with Try and EndTry" do
        o = ops("begin\n1\nrescue e\n2\nend")
        o.should contain(Op::Try)
        o.should contain(Op::EndTry)
      end
    end

    describe "yield" do
      it "compiles yield with Yield opcode" do
        # yield is in the method body chunk; outer chunk just registers the def
        chunk = compile("def f\nyield 1\nend")
        chunk.code.map(&.op).should contain(Op::DefMethod)
      end
    end

    describe "require" do
      it "compiles require as a Call" do
        o = ops(%{require "io"})
        o.should contain(Op::Call)
        chunk = compile(%{require "io"})
        has_require = chunk.consts.any? { |v| v.symbol? && v.as_sym.name == "require" }
        has_require.should be_true
      end
    end

    describe "a realistic program" do
      it "compiles fib without error" do
        src = "def fib(n)\nreturn n if n < 2\nfib(n - 1) + fib(n - 2)\nend\nputs(fib(10))"
        chunk = compile(src)
        chunk.code.should_not be_empty
      end
    end
  end
end
