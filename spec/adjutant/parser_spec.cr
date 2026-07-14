require "../spec_helper"

module Adjutant
  private def self.parse(source : String) : Body
    Parser.new(source).parse
  end

  private def self.parse_expr(source : String) : Node
    body = parse(source)
    body.stmts.first
  end

  describe Parser do
    describe "literals" do
      it "parses nil" do
        parse_expr("nil").should be_a(NilLiteral)
      end

      it "parses true" do
        node = parse_expr("true")
        node.should be_a(BoolLiteral)
        node.as(BoolLiteral).value.should be_true
      end

      it "parses false" do
        node = parse_expr("false")
        node.as(BoolLiteral).value.should be_false
      end

      it "parses an integer" do
        node = parse_expr("42")
        node.should be_a(IntLiteral)
        node.as(IntLiteral).value.should eq "42"
      end

      it "parses a float" do
        node = parse_expr("3.14")
        node.should be_a(FloatLiteral)
        node.as(FloatLiteral).value.should eq "3.14"
      end

      it "parses a string literal" do
        node = parse_expr(%("hello"))
        node.should be_a(StringLiteral)
        node.as(StringLiteral).value.should eq "hello"
      end

      it "parses a symbol" do
        node = parse_expr(":ok")
        node.should be_a(SymbolLiteral)
        node.as(SymbolLiteral).value.should eq "ok"
      end

      it "parses an array literal" do
        node = parse_expr("[1, 2, 3]")
        node.should be_a(ArrayLiteral)
        node.as(ArrayLiteral).elements.size.should eq 3
      end

      it "parses an empty array" do
        node = parse_expr("[]")
        node.as(ArrayLiteral).elements.should be_empty
      end

      it "parses a hash literal" do
        node = parse_expr(%({ "a" => 1 }))
        node.should be_a(HashLiteral)
        node.as(HashLiteral).pairs.size.should eq 1
      end

      it "parses an inclusive range" do
        node = parse_expr("1..10")
        node.should be_a(RangeLiteral)
        node.as(RangeLiteral).exclusive?.should be_false
      end

      it "parses an exclusive range" do
        node = parse_expr("1...10")
        node.as(RangeLiteral).exclusive?.should be_true
      end

      it "parses an interpolated string" do
        node = parse_expr("\"hello \#{name}!\"")
        node.should be_a(InterpString)
        parts = node.as(InterpString).parts
        parts.size.should eq 3
        parts[0].should be_a(StringFragment)
        parts[0].as(StringFragment).value.should eq "hello "
        parts[1].should be_a(Identifier)
        parts[2].should be_a(StringFragment)
        parts[2].as(StringFragment).value.should eq "!"
      end
    end

    describe "variables" do
      it "parses an identifier" do
        node = parse_expr("foo")
        node.should be_a(Identifier)
        node.as(Identifier).name.should eq "foo"
      end

      it "parses a constant" do
        node = parse_expr("MyClass")
        node.should be_a(Constant)
        node.as(Constant).name.should eq "MyClass"
      end

      it "parses an instance variable" do
        node = parse_expr("@name")
        node.should be_a(IVar)
        node.as(IVar).name.should eq "@name"
      end

      it "parses a class variable" do
        node = parse_expr("@@count")
        node.should be_a(CVar)
        node.as(CVar).name.should eq "@@count"
      end

      it "parses self" do
        parse_expr("self").should be_a(SelfNode)
      end
    end

    describe "binary expressions" do
      it "parses addition" do
        node = parse_expr("a + b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::Plus
      end

      it "parses comparison" do
        node = parse_expr("x == y")
        node.as(Binary).op.should eq TokenKind::EqEq
      end

      it "respects precedence: * before +" do
        node = parse_expr("a + b * c")
        node.should be_a(Binary)
        top = node.as(Binary)
        top.op.should eq TokenKind::Plus
        top.right.should be_a(Binary)
        top.right.as(Binary).op.should eq TokenKind::Star
      end

      it "parses logical and" do
        node = parse_expr("a && b")
        node.as(Binary).op.should eq TokenKind::AndAnd
      end

      it "parses logical or" do
        node = parse_expr("a || b")
        node.as(Binary).op.should eq TokenKind::OrOr
      end
    end

    describe "unary expressions" do
      it "parses negation" do
        node = parse_expr("-x")
        node.should be_a(Unary)
        node.as(Unary).op.should eq TokenKind::Minus
      end

      it "parses not" do
        node = parse_expr("!x")
        node.as(Unary).op.should eq TokenKind::Bang
      end
    end

    describe "ternary" do
      it "parses ternary expression" do
        node = parse_expr("a ? b : c")
        node.should be_a(Ternary)
      end
    end

    describe "assignment" do
      it "parses simple assignment" do
        node = parse_expr("x = 1")
        node.should be_a(Assign)
        node.as(Assign).target.as(Identifier).name.should eq "x"
        node.as(Assign).value.as(IntLiteral).value.should eq "1"
      end

      it "parses += compound assignment" do
        node = parse_expr("x += 1")
        node.should be_a(OpAssign)
        node.as(OpAssign).op.should eq TokenKind::Plus
      end

      it "parses ||= conditional assignment" do
        node = parse_expr("x ||= nil")
        node.should be_a(CondAssign)
        node.as(CondAssign).op.should eq TokenKind::OrAssign
      end
    end

    describe "method calls" do
      it "parses a bare call with parens" do
        node = parse_expr("puts(42)")
        node.should be_a(Call)
        c = node.as(Call)
        c.method.should eq "puts"
        c.args.size.should eq 1
        c.receiver.should be_nil
      end

      it "parses a receiver call" do
        node = parse_expr("foo.bar")
        node.should be_a(Call)
        c = node.as(Call)
        c.method.should eq "bar"
        c.receiver.should be_a(Identifier)
      end

      it "parses a safe navigation call" do
        node = parse_expr("foo&.bar")
        node.as(Call).safe?.should be_true
      end

      it "parses a chained call" do
        node = parse_expr("a.b.c")
        node.should be_a(Call)
        node.as(Call).method.should eq "c"
        node.as(Call).receiver.should be_a(Call)
      end

      it "parses indexing" do
        node = parse_expr("arr[0]")
        node.should be_a(Index)
      end

      it "parses index assignment" do
        node = parse_expr("arr[0] = 1")
        node.should be_a(IndexAssign)
      end
    end

    describe "def" do
      it "parses a simple method def" do
        node = parse_expr("def greet\nend")
        node.should be_a(DefNode)
        node.as(DefNode).name.should eq "greet"
        node.as(DefNode).params.should be_empty
      end

      it "parses a def with params" do
        node = parse_expr("def add(a, b)\nend")
        node.as(DefNode).params.size.should eq 2
      end

      it "parses a def with a default param" do
        node = parse_expr("def greet(name = \"world\")\nend")
        param = node.as(DefNode).params.first
        param.default.should_not be_nil
      end

      it "parses a def with a splat param" do
        node = parse_expr("def sum(*args)\nend")
        node.as(DefNode).params.first.splat?.should be_true
      end

      it "parses a def with body" do
        node = parse_expr("def double(x)\nx * 2\nend")
        body = node.as(DefNode).body
        body.stmts.size.should eq 1
      end
    end

    describe "class and module" do
      it "parses a class definition" do
        node = parse_expr("class Dog\nend")
        node.should be_a(ClassNode)
        node.as(ClassNode).name.should eq "Dog"
      end

      it "parses a class with superclass" do
        node = parse_expr("class Poodle < Dog\nend")
        node.as(ClassNode).superclass.should eq "Dog"
      end

      it "parses a module definition" do
        node = parse_expr("module Greetable\nend")
        node.should be_a(ModuleNode)
        node.as(ModuleNode).name.should eq "Greetable"
      end
    end

    describe "control flow" do
      it "parses an if statement" do
        node = parse_expr("if x\ny\nend")
        node.should be_a(IfNode)
      end

      it "parses if/elsif/else" do
        node = parse_expr("if a\n1\nelsif b\n2\nelse\n3\nend")
        n = node.as(IfNode)
        n.elsif_branches.size.should eq 1
        n.else_branch.should_not be_nil
      end

      it "parses unless" do
        node = parse_expr("unless x\ny\nend")
        node.should be_a(UnlessNode)
      end

      it "parses a while loop" do
        node = parse_expr("while x > 0\nx -= 1\nend")
        node.should be_a(WhileNode)
        node.as(WhileNode).until_loop?.should be_false
      end

      it "parses an until loop" do
        node = parse_expr("until x == 0\nx -= 1\nend")
        node.as(WhileNode).until_loop?.should be_true
      end

      it "parses a while loop with a trailing do" do
        node = parse_expr("while x > 0 do\nx -= 1\nend")
        node.should be_a(WhileNode)
      end

      it "parses an until loop with a trailing do" do
        node = parse_expr("until x == 0 do\nx -= 1\nend")
        node.should be_a(WhileNode)
        node.as(WhileNode).until_loop?.should be_true
      end

      it "parses a while loop whose condition ends in a bare identifier, with do" do
        # Regression: `running do` used to parse as a parenless
        # call-with-block on `running`, swallowing the while-loop's
        # own `end`.
        node = parse_expr("while running do\nstep\nend")
        node.should be_a(WhileNode)
      end

      it "parses a while loop whose condition ends in a dot-call, with do" do
        # Regression: the same ambiguity applies to a parenless
        # dot-call as the rightmost primary before `do` (`a.size do`),
        # not just a bare identifier — block_follows_no_paren? is
        # checked from parse_call_args_and_block too.
        node = parse_expr("while i < a.size do\ni += 1\nend")
        node.should be_a(WhileNode)
      end

      it "parses a for loop" do
        node = parse_expr("for i in 1..3\nputs(i)\nend")
        node.should be_a(ForNode)
        node.as(ForNode).vars.should eq ["i"]
      end

      it "parses a for loop over a bare-identifier iterable with a trailing do" do
        # Regression: `a do` used to parse as a parenless call-with-
        # block on `a`, swallowing the for-loop's own `end` and
        # leaving the parser expecting KwEnd at EOF.
        node = parse_expr("for o in a do\nputs(o)\nend")
        node.should be_a(ForNode)
        node.as(ForNode).vars.should eq ["o"]
        node.as(ForNode).iter.should be_a(Identifier)
      end

      it "parses a for loop over a bare-identifier iterable without do" do
        node = parse_expr("for o in a\nputs(o)\nend")
        node.should be_a(ForNode)
        node.as(ForNode).iter.should be_a(Identifier)
      end

      it "still parses a normal parenless call-with-block outside a for-loop" do
        # Confirms the no_do_block suppression is properly scoped to
        # the for-loop's iterable and doesn't leak into unrelated
        # parsing.
        node = parse_expr("foo do\n1\nend")
        node.should be_a(Call)
        node.as(Call).block.should_not be_nil
      end

      it "parses a case statement" do
        node = parse_expr("case x\nwhen 1\n:one\nwhen 2\n:two\nend")
        node.should be_a(CaseNode)
        node.as(CaseNode).whens.size.should eq 2
      end

      it "parses return" do
        node = parse_expr("return 42")
        node.should be_a(ReturnNode)
        node.as(ReturnNode).value.should be_a(IntLiteral)
      end

      it "parses bare return" do
        node = parse_expr("return")
        node.as(ReturnNode).value.should be_nil
      end

      it "parses break" do
        parse_expr("break").should be_a(BreakNode)
      end

      it "parses next" do
        parse_expr("next").should be_a(NextNode)
      end

      it "parses modifier if" do
        node = parse_expr("puts(x) if x")
        node.should be_a(ModifierIf)
        node.as(ModifierIf).negated?.should be_false
      end

      it "parses modifier unless" do
        node = parse_expr("puts(x) unless x.null?")
        node.should be_a(ModifierIf)
        node.as(ModifierIf).negated?.should be_true
      end

      it "parses modifier while" do
        node = parse_expr("x -= 1 while x > 0")
        node.should be_a(ModifierWhile)
      end
    end

    describe "expression-position control flow" do
      it "parses if as assignment rhs" do
        node = parse_expr("x = if a\n1\nelse\n2\nend")
        assign = node.as(Assign)
        assign.value.should be_a(IfNode)
      end

      it "parses if/elsif/else as assignment rhs" do
        node = parse_expr("x = if a\n1\nelsif b\n2\nelse\n3\nend")
        n = node.as(Assign).value.as(IfNode)
        n.elsif_branches.size.should eq 1
      end

      it "parses if result compared in a binary expression" do
        node = parse_expr("(if a\n1\nelse\n2\nend) == x")
        bin = node.as(Binary)
        bin.left.should be_a(IfNode)
      end

      it "parses unless as assignment rhs" do
        node = parse_expr("x = unless a\n1\nelse\n2\nend")
        node.as(Assign).value.should be_a(UnlessNode)
      end

      it "parses case as assignment rhs" do
        node = parse_expr("x = case y\nwhen 1\n:one\nelse\n:other\nend")
        n = node.as(Assign).value.as(CaseNode)
        n.whens.size.should eq 1
      end

      it "parses begin/rescue as assignment rhs" do
        node = parse_expr("x = begin\nfoo\nrescue e\nbar\nend")
        n = node.as(Assign).value.as(BeginNode)
        n.rescue_var.should eq "e"
      end

      it "parses if as a call argument" do
        node = parse_expr("puts(if a\n1\nelse\n2\nend)")
        call = node.as(Call)
        call.args.first.should be_a(IfNode)
      end

      it "statement-position if is unaffected" do
        node = parse_expr("if x\ny\nend")
        node.should be_a(IfNode)
      end
    end

    describe "blocks" do
      it "parses a do...end block" do
        node = parse_expr("[1,2].each do |x|\nputs(x)\nend")
        call = node.as(Call)
        call.block.should_not be_nil
        call.block.not_nil!.params.size.should eq 1
      end

      it "parses a brace block" do
        node = parse_expr("[1,2].each { |x| puts(x) }")
        call = node.as(Call)
        call.block.should_not be_nil
      end
    end

    describe "begin/rescue/ensure" do
      it "parses begin/rescue/ensure" do
        src = "begin\nfoo\nrescue e\nbar\nensure\nbaz\nend"
        node = parse_expr(src)
        node.should be_a(BeginNode)
        b = node.as(BeginNode)
        b.rescue_var.should eq "e"
        b.rescue_body.should_not be_nil
        b.ensure_body.should_not be_nil
      end

      it "parses rescue ClassName => var" do
        src = "begin\nfoo\nrescue TypeError => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_a(Constant)
        b.rescue_class.as(Constant).name.should eq "TypeError"
        b.rescue_var.should eq "e"
      end

      it "parses rescue ClassName with no bound variable" do
        src = "begin\nfoo\nrescue TypeError\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_a(Constant)
        b.rescue_var.should be_nil
      end

      it "parses rescue => var with no class filter" do
        src = "begin\nfoo\nrescue => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_nil
        b.rescue_var.should eq "e"
      end

      it "parses a qualified class path in rescue" do
        src = "begin\nfoo\nrescue Foo::Bar => e\nbar\nend"
        b = parse_expr(src).as(BeginNode)
        b.rescue_class.should be_a(ConstPath)
      end
    end

    describe "require" do
      it "parses require" do
        node = parse_expr(%{require "io"})
        node.should be_a(RequireNode)
        node.as(RequireNode).path.as(StringLiteral).value.should eq "io"
      end
    end

    describe "source position" do
      it "records line numbers" do
        node = parse_expr("42")
        node.line.should eq 1
      end

      it "records line for second-line token" do
        body = parse("foo\nbar")
        body.stmts[1].line.should eq 2
      end
    end

    describe "a realistic program" do
      it "parses a multi-statement program" do
        src = <<-RUBY
          def fib(n)
            return n if n < 2
            fib(n - 1) + fib(n - 2)
          end
          puts(fib(10))
        RUBY
        body = parse(src)
        body.stmts.size.should eq 2
        body.stmts[0].should be_a(DefNode)
        body.stmts[1].should be_a(Call)
      end
    end
  end
end
