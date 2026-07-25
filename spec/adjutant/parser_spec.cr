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

      # Fixed 2026-07-25 (SCOPE.md's "Unary minus on a
      # NEGATIVE-NUMERIC-LITERAL binds looser than postfix" entry).
      # `-` immediately adjacent (no space) to a numeric literal fuses
      # into a single negative-literal node — NOT a Unary wrapping
      # anything — confirmed as the correct rule via a series of `irb`
      # experiments and Ruby's own parse.y grammar (tUMINUS_NUM),
      # distinct from the general "does unary minus bind tighter than
      # postfix" question, which it does NOT for anything other than
      # an immediately-adjacent literal.
      it "fuses minus with an immediately-adjacent integer literal (no Unary node)" do
        node = parse_expr("-7")
        node.should be_a(IntLiteral)
        node.as(IntLiteral).value.should eq "-7"
      end

      it "fuses minus with an immediately-adjacent float literal (no Unary node)" do
        node = parse_expr("-0.0")
        node.should be_a(FloatLiteral)
        node.as(FloatLiteral).value.should eq "-0.0"
      end

      it "applies postfix chaining to the FUSED literal, not to a Unary wrapping a postfix chain" do
        # This is the actual originally-reported bug shape:
        # `-0.0.to_s` must group as `(-0.0).to_s`, i.e. a Call whose
        # RECEIVER is the fused negative FloatLiteral — not a Unary
        # wrapping a Call on a positive 0.0.
        node = parse_expr("-0.0.to_s")
        node.should be_a(Call)
        call = node.as(Call)
        call.method.should eq "to_s"
        call.receiver.should be_a(FloatLiteral)
        call.receiver.as(FloatLiteral).value.should eq "-0.0"
      end

      it "does NOT fuse when there is a space between minus and the literal" do
        # `- 0.0.to_s` must still parse as the general Unary-wraps-
        # postfix form — `-(0.0.to_s)` — same as `-a.to_s` for a
        # variable. Confirmed empirically (irb): `- 0.0.to_s` groups
        # as unary-minus-of-the-call-result, NOT as a fused negative
        # literal, distinguishing this from the no-space case above by
        # whitespace alone (matching Ruby's own tUMINUS_NUM adjacency
        # rule, not a general precedence difference).
        node = parse_expr("- 0.0.to_s")
        node.should be_a(Unary)
        unary = node.as(Unary)
        unary.op.should eq TokenKind::Minus
        unary.expr.should be_a(Call)
      end

      it "does NOT fuse minus with a variable, even with no space" do
        # `-a.to_s` (a is a variable, not a literal) must remain
        # Unary(Minus, Call(...)) — negating the call's RESULT, per
        # Ruby's own documented behavior (bugs.ruby-lang.org/issues/
        # 19583) — regardless of adjacency, since fusion only ever
        # applies to a genuine numeric LITERAL token, never an
        # identifier.
        node = parse_expr("-a.to_s")
        node.should be_a(Unary)
        node.as(Unary).expr.should be_a(Call)
      end

      it "parses not" do
        node = parse_expr("!x")
        node.as(Unary).op.should eq TokenKind::Bang
      end

      # Fixed 2026-07-25 (SCOPE.md's "Unary + is entirely unsupported"
      # entry) — previously a parse error (`unexpected token Plus`)
      # since parse_unary had no TokenKind::Plus case at all.
      it "parses unary plus" do
        node = parse_expr("+x")
        node.should be_a(Unary)
        node.as(Unary).op.should eq TokenKind::Plus
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
        # `arr` must be established as a known local first — bare
        # `identifier [expr]` with no prior assignment parses as a
        # CALL with an array-literal argument instead, matching real
        # Ruby (see the "identifier vs. index disambiguation" describe
        # block below for the dedicated coverage of that rule).
        node = parse("arr = []\narr[0]").stmts.last
        node.should be_a(Index)
      end

      it "parses index assignment" do
        node = parse("arr = []\narr[0] = 1").stmts.last
        node.should be_a(IndexAssign)
      end
    end

    describe "identifier vs. index disambiguation (`name [expr]`)" do
      # Real Ruby's own parse-time rule, confirmed via a series of
      # `irb` experiments 2026-07-21 (see parser.cr's @local_scopes
      # comment for the full trace): a name already established as a
      # local in the currently-open scope ALWAYS means indexing from
      # that point on, regardless of what it holds at runtime; an
      # unestablished name ALWAYS means a bare call, even one that
      # turns out at runtime not to resolve to any real method either
      # — that failure happens later (VM name_error), not here. This
      # was the root cause of the SCOPE.md parser bug (`assert_equal
      # [3, 9, 16], ar` — `assert_equal` was never assigned, so `[`
      # must start a bare call argument, not index `assert_equal`
      # itself).
      it "treats `name [expr]` as indexing once `name` is a known local" do
        node = parse("x = [1,2,3]\nx [0]").stmts.last
        node.should be_a(Index)
      end

      it "treats `name [expr]` as a call with an array-literal argument when `name` is not a known local" do
        node = parse("assert_equal [3, 9, 16], ar").stmts.first
        node.should be_a(Call)
        call = node.as(Call)
        call.method.should eq "assert_equal"
        call.args.size.should eq 2
        call.args.first.should be_a(ArrayLiteral)
      end

      it "a `def` body does not see an outer local for this purpose (fresh scope)" do
        node = parse(<<-RUBY).stmts.last.as(DefNode).body.stmts.last
          x = [1,2,3]
          def f
            x [0]
          end
        RUBY
        node.should be_a(Call)
      end

      it "a block DOES see an outer local for this purpose (inherits, not fresh)" do
        node = parse(<<-RUBY).stmts.last.as(Call).block.not_nil!.body.stmts.last
          x = [1,2,3]
          [1].each { x [0] }
        RUBY
        node.should be_a(Index)
      end

      it "a lambda DOES see an outer local for this purpose (inherits, not fresh)" do
        node = parse(<<-RUBY).stmts.last.as(Lambda).body.stmts.last
          x = [1,2,3]
          ->() { x [0] }
        RUBY
        node.should be_a(Index)
      end

      it "a def parameter counts as a known local inside that def's body" do
        node = parse(<<-RUBY).stmts.first.as(DefNode).body.stmts.last
          def f(x)
            x [0]
          end
        RUBY
        node.should be_a(Index)
      end

      it "a block parameter counts as a known local inside that block's body" do
        node = parse("[1,2,3].each { |x| x [0] }").stmts.first.as(Call).block.not_nil!.body.stmts.last
        node.should be_a(Index)
      end

      it "a name assigned inside a block does not leak out to the enclosing scope" do
        node = parse(<<-RUBY).stmts.last
          [1].each { y = [1,2,3] }
          y [0]
        RUBY
        node.should be_a(Call)
      end

      it "a for-loop variable counts as a known local, including after the loop (no new scope)" do
        node = parse(<<-RUBY).stmts.last
          for x in [1,2,3]
          end
          x [0]
        RUBY
        node.should be_a(Index)
      end

      it "a rescue-bound variable counts as a known local, including after the begin/end (no new scope)" do
        node = parse(<<-RUBY).stmts.last
          begin
          rescue => e
          end
          e [0]
        RUBY
        node.should be_a(Index)
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
