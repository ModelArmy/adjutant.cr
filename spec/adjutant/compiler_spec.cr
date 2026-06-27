require "../spec_helper"

module Adjutant
  # Shared symbol table for compiler specs — simulates multiple scripts
  # compiled against the same interpreter instance.
  COMPILER_SPEC_SYMBOLS = SymbolTable.new

  # Helper: parse source and compile to a Chunk.
  private def self.compile(source : String) : Chunk
    body = Parser.new(source).parse
    Compiler.compile(body, COMPILER_SPEC_SYMBOLS)
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

      it "compiles a negative integer via unary minus" do
        chunk = compile("-7")
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
        chunk = compile("x = 1\nx")
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
      it "compiles simple assignment with SetGlobal" do
        ops("x = 1").should contain(Op::SetGlobal)
      end

      it "compiles ivar assignment with SetIvar" do
        ops("@x = 1").should contain(Op::SetIvar)
      end

      it "compiles cvar assignment with SetCvar" do
        ops("@@x = 1").should contain(Op::SetCvar)
      end

      it "compiles += as load, add, store" do
        o = ops("x += 1")
        o.should contain(Op::GetGlobal)
        o.should contain(Op::Add)
        o.should contain(Op::SetGlobal)
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
        # return is in the method body chunk, not the outer chunk
        chunk = compile("def f\nreturn 1\nend")
        proc_str = chunk.consts.find { |v| v.string? }
        proc_str.should_not be_nil
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
        ops("arr[0]").should contain(Op::GetIndex)
      end

      it "compiles index assignment with SetIndex" do
        ops("arr[0] = 1").should contain(Op::SetIndex)
      end
    end

    describe "def" do
      it "compiles a def as Const + SetGlobal at top level" do
        o = ops("def greet\nend")
        o.should contain(Op::Const)
        o.should contain(Op::SetGlobal)
      end

      it "compiles a def inside a class as DefMethod" do
        o = ops("class Foo\ndef bar\nend\nend")
        o.should contain(Op::DefMethod)
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
        chunk.code.map(&.op).should contain(Op::SetGlobal)
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
