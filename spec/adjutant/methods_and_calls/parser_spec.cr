require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "method calls" do
      it "parses a bare call with parens" do
        node = parse_expr("puts(42)")
        node.should be_a(Call)
        c = node.as(Call)
        c.method.should eq "puts"
        c.args.size.should eq 1
        c.receiver.should be_nil
      end

      # Fixed 2026-07-25 (found by the person) — a bare call whose
      # FIRST argument starts with `-` never got recognized as a call
      # at all: `eq -1, -1` parsed `eq` as a standalone Identifier,
      # then `-1, -1` separately, producing an "unexpected token Comma"
      # parse error once the second `-1`'s comma had nowhere to go.
      # `eq(-1, -1)` (parens) already worked, confirming the bug was
      # specific to the no-paren bare-call path.
      #
      # This is NOT resolved by known_local? (the disambiguator that
      # already correctly resolves the `name [expr]` ambiguity) — a
      # first attempt using known_local? was caught, before shipping,
      # breaking two pre-existing specs: `a + b` (Plus, not fixed here
      # — see SCOPE.md) and, by the same flawed logic applied to Minus,
      # `a - b`/`n - 1` would have broken too, since neither `a` nor
      # `n` needs to be a known local for these to still mean binary
      # subtraction. The actual disambiguator, confirmed via `irb`
      # (`def a; 999; end; p a -1` → `ArgumentError: given 1, expected
      # 0`, i.e. parsed as `a(-1)`, one argument — even though `a` has
      # no local-status at all) and Ruby's own "interpreted as binary
      # operator" warning text: whether `-` is IMMEDIATELY ADJACENT (no
      # space) to what follows it — `operand_immediately_follows?`,
      # column arithmetic using the parser's existing one-token
      # lookahead, same technique as the minus-literal-fusion fix.
      it "parses a bare call whose first argument is a negative literal" do
        node = parse_expr("eq -1, -1")
        node.should be_a(Call)
        c = node.as(Call)
        c.method.should eq "eq"
        c.args.size.should eq 2
        c.args[0].should be_a(IntLiteral)
        c.args[0].as(IntLiteral).value.should eq "-1"
        c.args[1].should be_a(IntLiteral)
        c.args[1].as(IntLiteral).value.should eq "-1"
      end

      it "parses a bare call whose first argument is unary-minus on a variable" do
        # Not just a fused literal — a genuine Unary(Minus, ...) as the
        # very first argument must also be recognized as starting a
        # bare call, same fix: `-x` (no space) still counts as
        # "operand immediately follows," even though `x` isn't a
        # literal and doesn't fuse with the `-` the way a numeric
        # literal does.
        node = parse("x = 5\neq -x, 1").stmts.last
        node.should be_a(Call)
        c = node.as(Call)
        c.args[0].should be_a(Unary)
        c.args[0].as(Unary).op.should eq TokenKind::Minus
      end

      it "still parses a bare call with a single negative-literal argument (no comma)" do
        node = parse_expr("puts -5")
        node.should be_a(Call)
        node.as(Call).args.first.should be_a(IntLiteral)
      end

      # Explicit regression coverage for the exact two shapes that
      # broke CI in a discarded first (known_local?-based) attempt at
      # this fix — see the fix's own comment for the full trace of why
      # adjacency, not known_local?, is the correct disambiguator.
      it "still parses subtraction as a binary operator, spaced on both sides, regardless of local status" do
        node = parse_expr("a - b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::Minus
      end

      it "still parses subtraction as a binary operator for a known local specifically" do
        node = parse("n = 5\nn - 1").stmts.last
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::Minus
      end

      # Found 2026-07-26 via a FAILING PRE-EXISTING test SCRIPT (not a
      # new spec written for this fix) — `spec/scripts/methods.rb`'s
      # `def self.add(a,b); a+b; end` raised "undefined method or
      # variable: a" once the Plus half of this branch shipped. Root
      # cause: the branch's condition checked ONLY
      # `operand_immediately_follows?` (no space between the operator
      # and what follows it) — it never also required space BEFORE the
      # operator. `a-b`/`a+b` (no space anywhere) satisfies "no space
      # after" just as much as `eq -1` does, so it was being
      # misidentified as a bare-call start (`a(-b)`/`a(+b)`) instead of
      # ordinary Binary(a, -/+, b). This is a real, previously-
      # unguarded gap in the ORIGINAL Minus-only fix too (not something
      # the Plus change introduced) — `a-b` was simply never exercised
      # by any pre-existing spec, unlike `a - b` (spaced) and `eq -1`
      # (space-before-only), which were. Fixed by requiring BOTH
      # `@current.space_before?` (space before the operator) AND
      # `operand_immediately_follows?` (no space after it) — see the
      # branch's own updated comment for the full trace.
      it "parses subtraction as a binary operator with no space on either side" do
        node = parse_expr("a-b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::Minus
      end

      it "parses addition as a binary operator with no space on either side" do
        node = parse_expr("a+b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::Plus
      end

      it "parses addition as a binary operator, spaced on both sides, regardless of local status" do
        node = parse_expr("a + b")
        node.should be_a(Binary)
        node.as(Binary).op.should eq TokenKind::Plus
      end

      # Positive coverage for the Plus half of this branch (the parked
      # `Must Fix` item this session unblocked) — mirrors the
      # already-covered Minus shape above.
      it "parses a bare call whose first argument is a positive literal" do
        node = parse_expr("eq +1, -1")
        node.should be_a(Call)
        c = node.as(Call)
        c.method.should eq "eq"
        c.args.size.should eq 2
        c.args[0].should be_a(Unary)
        c.args[0].as(Unary).op.should eq TokenKind::Plus
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

      # Found 2026-08-08: the same class of bug `"==="` needed a
      # dedicated `TripleEq` token for (see
      # OVERLOADABLE_OPERATOR_NAMES's own comment, compiler.cr) —
      # `def name=(v)` had never actually been parseable at all.
      # Without adjacency-based recognition, the `name` token and the
      # following `Eq` token were simply grabbed and dropped
      # separately: `name` became the whole method name, params
      # parsing found no `(` immediately after (it saw `Eq` instead)
      # and stayed empty, and the parser then tried to parse the
      # METHOD BODY starting at the stray `=`, raising a confusing,
      # unrelated-looking P002. `attr_writer`/`attr_accessor` never
      # hit this, since `Parser#parse_attr` builds its synthetic
      # DefNodes with a "name="-suffixed Crystal string directly,
      # bypassing this token-by-token path entirely — a HAND-WRITTEN
      # setter def was the first thing to actually exercise it.
      it "parses a hand-written setter method def (name=) as a single method name" do
        node = parse_expr("def value=(v)\n@value = v\nend")
        node.should be_a(DefNode)
        d = node.as(DefNode)
        d.name.should eq "value="
        d.params.size.should eq 1
        d.params.first.name.should eq "v"
      end

      it "a setter def works with a receiver too (def self.value=(v))" do
        node = parse_expr("def self.value=(v)\nend")
        d = node.as(DefNode)
        d.name.should eq "value="
        d.receiver.should be_a(SelfNode)
      end

      it "does NOT confuse a real == operator def with a setter-name shape" do
        # `def ==` tokenizes as Identifier + EqEq, not Identifier +
        # adjacent lone Eq — no ambiguity for the fix to resolve here,
        # but worth a regression: OVERLOADABLE_OPERATOR_NAMES rejects
        # `==` at COMPILE time (U017), so this should still parse
        # successfully as a DefNode named "==" and fail only later,
        # at compile time — not get misparsed as some "= =" shape.
        node = parse_expr("def ==(other)\nend")
        node.as(DefNode).name.should eq "=="
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

      # Was spec/scripts/keyword_params_callsite.rb, moved here
      # 2026-07-27, and originally asserted call-site keyword syntax
      # was a ParseError (see SCOPE.md's Must Fix entry, now closed).
      # Kept in the same spot now that the entry's resolved, covering
      # both call shapes and the one real ambiguity a bare `name:`
      # lookahead has to get right: a ternary's `? a : b`, whose colon
      # is never the SECOND token of an argument the way a genuine
      # `name:` kwarg's always is.
      it "parses keyword arguments at a parenthesized call site" do
        node = parse_expr(%(greet(name: "Ruby", "positional")))
        call = node.as(Call)
        call.args.size.should eq 1
        call.kwargs.size.should eq 1
        call.kwargs.first[0].should eq "name"
        call.kwargs.first[1].should be_a(StringLiteral)
      end

      it "parses keyword arguments at a bare (no-paren) call site" do
        node = parse_expr(%(puts x: 1, y: 2))
        call = node.as(Call)
        call.args.should be_empty
        call.kwargs.map(&.first).should eq ["x", "y"]
      end

      it "does not mistake a ternary's `:` for a keyword argument" do
        node = parse_expr(%(f(cond ? a : b)))
        call = node.as(Call)
        call.kwargs.should be_empty
        call.args.first.should be_a(Ternary)
      end

      it "points a missing `end` at the construct that lost it" do
        # The caret alone lands at EOF, far from the cause. The
        # secondary span is the part that makes this diagnosable.
        error = expect_raises(ParseError) do
          Parser.new("def outer\n  if x\n    y\n  end\n", "t.rb").parse
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("P003")
        diag.data["construct"].should eq("def")
        diag.secondary.size.should eq(1)
        diag.secondary.first.line.should eq(1)
        diag.secondary.first.label.not_nil!.should contain("never closed")
      end

      it "attributes the missing `end` to the innermost open construct" do
        # `if` is closed, `def` is not — so `def` is what's reported,
        # not merely the outermost or the most recent keyword seen.
        error = expect_raises(ParseError) do
          Parser.new("class A\n  def b\n", "t.rb").parse
        end
        diag = error.diagnostic.not_nil!
        diag.data["construct"].should eq("def")
        diag.secondary.first.line.should eq(2)
      end

      it "reports a plain P001 when the missing token isn't an `end`" do
        error = expect_raises(ParseError) do
          parse_expr("foo(1, 2")
        end
        error.diagnostic.not_nil!.code.should eq("P001")
      end

      it "parses a def with body" do
        node = parse_expr("def double(x)\nx * 2\nend")
        body = node.as(DefNode).body
        body.stmts.size.should eq 1
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

      # Found 2026-08-04 while adding tests for the default-parameter
      # prologue fix: `|x = 9|` failed to parse at all — `Pipe` is
      # both the block-param delimiter AND a real binary operator
      # (bitwise-or), so parse_expression(0) parsing the default kept
      # going past the closing `|`, consuming into the block BODY and
      # eventually erroring on an unexpected `}`. Fixed via @no_pipe
      # (parser.cr, see that flag's own comment for the full
      # mechanism) — these pin the parse-level shape;
      # methods_and_calls/vm_spec.cr's "argument binding — defaults and
      # splats" and methods_and_calls/compiler_spec.cr's
      # "default-parameter prologue" cover that the VALUE actually
      # binds correctly at runtime.
      it "parses a block param with a default value" do
        node = parse_expr("[1].each { |x = 9| x }")
        call = node.as(Call)
        param = call.block.not_nil!.params.first
        param.default.should_not be_nil
      end

      it "parses a block param with a default AFTER an earlier required param" do
        # The shape that actually failed originally — `b`'s default
        # isn't the first thing after the opening pipe.
        node = parse_expr("[1].each { |a, b = 9| a }")
        call = node.as(Call)
        params = call.block.not_nil!.params
        params[0].default.should be_nil
        params[1].default.should_not be_nil
      end

      it "parses a do...end block param with a default value" do
        # Same bug, the other block syntax — parse_block's fix covers
        # both branches, so this must be unaffected too.
        node = parse_expr("[1].each do |x = 9|\nx\nend")
        call = node.as(Call)
        param = call.block.not_nil!.params.first
        param.default.should_not be_nil
      end

      it "parses a block param with a KEYWORD default value (name: 9)" do
        # parse_param's kwarg branch had the identical latent bug —
        # its own Pipe guard only covered an EMPTY default (`name:`),
        # not a real expression like `name: 9`.
        node = parse_expr("[1].each { |k: 9| k }")
        call = node.as(Call)
        param = call.block.not_nil!.params.first
        param.kwarg?.should be_true
        param.default.should_not be_nil
      end

      it "does not let a suspended default-value Pipe restriction leak into a NESTED block literal's own params or body" do
        # @no_pipe must be suspended (not just left armed) around
        # parse_block itself — otherwise an outer param's default
        # value that CONTAINS its own block literal would incorrectly
        # treat that inner block's `|y|` delimiters, or a bare `|` in
        # its body, as the OUTER block's closing pipe too early.
        node = parse_expr("[1].each { |g = [2].map { |y| y | 1 }.first| g }")
        call = node.as(Call)
        outer_param = call.block.not_nil!.params.first
        outer_param.default.should_not be_nil
        # If the inner block's body (`y | 1`) had been mis-parsed as
        # terminating early on `|`, this whole expression wouldn't
        # have parsed as ONE call at all — reaching here at all is
        # most of the assertion; the block's own presence confirms
        # the outer `{ ... }` closed where it should have.
        call.block.not_nil!.body.should_not be_nil
      end
    end
  end
end
