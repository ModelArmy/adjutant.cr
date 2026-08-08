require "./token"
require "./lexer"
require "./ast"
require "./diagnostic"

module Adjutant
  class ParseError < Exception
    getter line : Int32
    getter column : Int32

    # See `CompileError#diagnostic` — nil for raise sites not yet
    # migrated to the diagnostic system.
    getter diagnostic : Diagnostic?

    def initialize(message : String, @line, @column)
      @diagnostic = nil
      super("#{message} (line #{line}, col #{column})")
    end

    def initialize(diagnostic : Diagnostic)
      @diagnostic = diagnostic
      # These raise sites always carry a span; the fallbacks exist
      # because `primary` is nilable for the H series, which never
      # reaches either of these classes.
      @line = diagnostic.primary.try(&.line) || 0
      @column = diagnostic.primary.try(&.column) || 0
      super(diagnostic.to_line)
    end
  end

  class Parser
    # When true, `block_follows_no_paren?` ignores a bare `do` as a
    # block-start signal. Set while parsing a `for`-loop's iterable
    # expression or a `while`/`until`'s condition expression, where a
    # trailing `do` belongs to the loop construct itself
    # (`for i in a do ... end`, `while i < a.size do ... end`), not to
    # a bare identifier immediately before it (`a do ... end` would
    # otherwise parse as a parenless call-with-block, consuming the
    # loop's own `end`). `{`-style blocks are unaffected — only
    # literal `do` is ambiguous with a loop construct's own `do`.
    @no_do_block = false

    # True only while parsing a single block/lambda PARAM's default
    # value (`|x = value|` — the `Eq` branch of parse_param, reached
    # only from parse_block_params). `Pipe` is a real binary operator
    # (bitwise-or, PRECEDENCE 7) AND the block-param-list delimiter, so
    # parse_expression's operator loop can't otherwise tell "here's the
    # closing `|`" from "here's a bitwise-or continuing the default" —
    # without this, `{ |x = 9| x }` parses `9| x }` as the start of a
    # (never-terminated) `9 | x` expression instead of stopping at the
    # closing pipe. Suspended (not just left on) around parse_block
    # itself — see that method — so a default value that CONTAINS its
    # own nested block literal (`def f(g = xs.each { |y| y })`) doesn't
    # leak this restriction into the nested block's own params or body,
    # which have nothing to do with the outer param list. Deliberately
    # narrower than a general "suspend inside any bracket" mechanism:
    # nothing needs `|` used as bitwise-or unparenthesized inside a
    # block-param default, so `{ |x = (a | b)| }` staying unsupported
    # is an acceptable, documentable restriction rather than added risk
    # for a case nothing exercises.
    @no_pipe = false

    # Tracks, per open scope, which bare names have been established as
    # locals so far in the CURRENT parse — used only to disambiguate
    # `name [expr]` (no dot, no explicit call syntax) between indexing
    # an existing local (`Index` node) and a bare call taking an
    # array-literal first argument (`Call` node). This mirrors real
    # Ruby's own parse-time rule exactly (confirmed via a series of
    # `irb` experiments — a local variable name, once assigned or bound
    # as a parameter, ALWAYS wins `name [x]` as indexing from that point
    # on in the same visible scope, regardless of what the variable
    # holds at runtime; an unassigned name always parses as a call,
    # even if it turns out at runtime to not be a real method either —
    # see `arg_follows_no_paren?`'s own comment for the resulting `[`
    # branch and 2026-07-21's design conversation).
    #
    # Deliberately NOT the same thing as `CompilerScope` (compiler.cr) —
    # this is a much shallower, syntax-only echo of it, existing a full
    # phase earlier, purely to answer "is this name known as a local
    # yet" during parsing. It does not need to be fully correct in
    # every exotic case `CompilerScope` handles (that's out of scope —
    # see SCOPE.md); it only needs to answer this one narrow question
    # the same way Ruby's own parser does.
    #
    # A `def` body gets a FRESH, empty scope (`def` does not close over
    # outer locals in Ruby — confirmed the same way `compile_lambda`'s
    # non-inheriting `def` scope already works, DEVELOPMENT.md's
    # scoping section). A block/lambda body INHERITS the enclosing
    # scope's names (blocks/lambdas DO close over outer locals) — done
    # by pushing a COPY of the current top set, not a live reference,
    # since nothing needs writes inside the block to propagate back out
    # (a block assigning a NEW name shouldn't make that name suddenly
    # known outside it either — matches Ruby). A `for`-loop variable or
    # a `rescue var` binding registers directly into the CURRENT scope
    # instead of pushing a new one at all — neither opens a new scope in
    # Ruby (confirmed: a for-loop's variable is readable after the loop
    # ends, same as a rescue-bound variable after the `begin/end`).
    @local_scopes = [Set(String).new]

    private def push_local_scope(inherit : Bool) : Nil
      @local_scopes.push(inherit ? @local_scopes.last.dup : Set(String).new)
    end

    private def pop_local_scope : Nil
      @local_scopes.pop
    end

    private def register_local(name : String) : Nil
      @local_scopes.last << name
    end

    private def known_local?(name : String) : Bool
      @local_scopes.last.includes?(name)
    end

    # True when @current (expected to be a Minus or Plus token, not yet
    # consumed) has NO whitespace between it and @next — i.e. the
    # operator is hugging its operand (`-1`, `+1`, `-x`), not a
    # spaced-out binary operator (`- 1`, `+ 1`, `- x`). Uses the
    # parser's existing one-token lookahead buffer (`@next`, populated
    # by `advance` — see the constructor and `advance` itself), so this
    # never needs to consume anything to check. Delegates to
    # `@next.space_before?` — the lexer now tracks this directly (see
    # `Token#space_before?`, set by `Lexer#skip_whitespace_and_comments`)
    # rather than this method reconstructing it from column arithmetic,
    # which is what an earlier version of this method did.
    private def operand_immediately_follows? : Bool
      !@next.space_before?
    end

    # Only a bare `Identifier` LHS introduces a new local name — `@ivar
    # = x`, `arr[0] = x`, `obj.attr = x` etc. are all valid assignment
    # targets too but none of them make a NEW bare name resolvable as a
    # local afterward.
    private def register_local_if_identifier(lhs : Node) : Nil
      register_local(lhs.name) if lhs.is_a?(Identifier)
    end

    # A block-forming construct the parser is currently inside, with
    # the position of the keyword that opened it.
    #
    # Exists so a missing `end` can point at the construct that was
    # never closed, rather than only at wherever the parser gave up.
    # Those are usually far apart and the second one is nearly useless
    # on its own: `expected KwEnd, got EOF` at the last line of a file
    # says nothing about which of the twelve `def`s above it lost its
    # `end`.
    record OpenBlock, kind : String, line : Int32, column : Int32

    def initialize(source : IO, filename : String = "<input>")
      @lexer = Lexer.new(source, filename)
      @current = @lexer.next_token
      @next = @lexer.next_token
    end

    # Delegates to the lexer, which read the whole IO up front. Safe
    # to call immediately after construction — which matters, because
    # a caller must be able to register the source BEFORE `parse`, or
    # a ParseError would be the one error with nothing to quote.
    def source : String
      @lexer.source
    end

    # Convenience constructor for string literals and tests.
    def initialize(source : String, filename : String = "<input>")
      initialize(IO::Memory.new(source), filename)
    end

    def parse : Body
      line = @current.line
      col = @current.column
      stmts = [] of Node
      skip_newlines
      until at_kind?(TokenKind::EOF)
        stmts << parse_statement
        skip_terminators
      end
      Body.new(stmts, line, col)
    end

    # --- Token navigation ---------------------------------------------------

    private def advance : Token
      tok = @current
      @current = @next
      @next = @lexer.next_token
      tok
    end

    private def current_kind : TokenKind
      @current.kind
    end

    private def at_kind?(kind : TokenKind) : Bool
      @current.kind == kind
    end

    private def at_any?(*kinds : TokenKind) : Bool
      kinds.includes?(@current.kind)
    end

    private def peek_kind : TokenKind
      @next.kind
    end

    # Constructs currently open, innermost last. Pushed by
    # `open_block`, popped by `close_block` — deliberately NOT popped
    # on the error path, since an abandoned entry is exactly the
    # information a missing-`end` diagnostic needs.
    @open_blocks = [] of OpenBlock

    private def open_block(kind : String, line : Int32, column : Int32) : Nil
      @open_blocks << OpenBlock.new(kind, line, column)
    end

    # Consumes the `end` that closes the innermost open construct.
    private def close_block : Token
      tok = expect(TokenKind::KwEnd)
      @open_blocks.pop?
      tok
    end

    private def expect(kind : TokenKind) : Token
      raise unexpected_token(kind) unless at_kind?(kind)
      advance
    end

    # The diagnostic for "we needed X and found Y".
    #
    # When the thing we needed was an `end`, the caret alone is close to
    # useless: it lands wherever the parser gave up, which for a missing
    # `end` is the bottom of the file, nowhere near the construct that
    # actually lost it. So that case adds a secondary span pointing at
    # the innermost construct still open — the one that swallowed
    # everything after it.
    private def unexpected_token(expected : TokenKind) : ParseError
      span = Span.new(
        line: @current.line,
        column: @current.column,
        length: caret_width(@current),
        label: "expected #{describe_kind(expected)}"
      )
      data = {
        "expected" => describe_kind(expected),
        "found"    => describe_token(@current),
      }

      # A missing `end` we can attribute to a specific open construct
      # is a different diagnostic, not a variant of this one: it has a
      # real explanation to offer, where P001 in general does not.
      if expected == TokenKind::KwEnd && (open = @open_blocks.last?)
        data["construct"] = open.kind
        return ParseError.new(
          Diagnostic.new(
            code: "P003",
            primary: span,
            secondary: [Span.new(
              line: open.line,
              column: open.column,
              length: open.kind.size,
              label: "this `#{open.kind}` is never closed"
            )],
            data: data
          )
        )
      end

      ParseError.new(
        Diagnostic.new(code: "P001", primary: span, data: data)
      )
    end

    # EOF has no text, so a caret would have nothing to sit under —
    # one column is the honest width there.
    private def caret_width(token : Token) : Int32
      token.kind == TokenKind::EOF ? 1 : Math.max(1, token.lexeme.size)
    end

    # Token kinds are internal enum names (`KwEnd`, `LParen`); a script
    # author never wrote either. Render what they would have typed.
    #
    # A lookup table rather than a `case`: the mapping is data, and as
    # a `case` it was a 14-branch method that only ever grows as more
    # kinds earn a friendly name.
    KIND_DESCRIPTIONS = {
      TokenKind::KwEnd    => "`end`",
      TokenKind::KwDo     => "`do`",
      TokenKind::KwThen   => "`then`",
      TokenKind::KwIn     => "`in`",
      TokenKind::LParen   => "`(`",
      TokenKind::RParen   => "`)`",
      TokenKind::LBrace   => "`{`",
      TokenKind::RBrace   => "`}`",
      TokenKind::LBracket => "`[`",
      TokenKind::RBracket => "`]`",
      TokenKind::Comma    => "`,`",
      TokenKind::EOF      => "end of file",
      TokenKind::Newline  => "a line break",
    }

    private def describe_kind(kind : TokenKind) : String
      KIND_DESCRIPTIONS[kind]? || "`#{kind}`"
    end

    private def describe_token(token : Token) : String
      token.kind == TokenKind::EOF ? "end of file" : "`#{token.lexeme}`"
    end

    private def match(kind : TokenKind) : Bool
      return false unless at_kind?(kind)
      advance
      true
    end

    private def skip_newlines
      while at_any?(TokenKind::Newline, TokenKind::Semi)
        advance
      end
    end

    private def skip_terminators
      advanced = false
      while at_any?(TokenKind::Newline, TokenKind::Semi)
        advance
        advanced = true
      end
      advanced
    end

    private def line : Int32
      @current.line
    end

    private def col : Int32
      @current.column
    end

    # --- Statement ----------------------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    private def parse_statement : Node
      l, c = line, col
      case current_kind
      when TokenKind::KwIf      then parse_if
      when TokenKind::KwUnless  then parse_unless
      when TokenKind::KwWhile   then parse_while(false)
      when TokenKind::KwUntil   then parse_while(true)
      when TokenKind::KwLoop    then parse_loop
      when TokenKind::KwFor     then parse_for
      when TokenKind::KwCase    then parse_case
      when TokenKind::KwDef     then parse_def
      when TokenKind::KwClass   then parse_class
      when TokenKind::KwModule  then parse_module
      when TokenKind::KwBegin   then reject_do_while(parse_begin)
      when TokenKind::KwReturn  then parse_return
      when TokenKind::KwBreak   then parse_break(BreakNode)
      when TokenKind::KwNext    then parse_break(NextNode)
      when TokenKind::KwRedo    then advance; RedoNode.new(l, c)
      when TokenKind::KwRetry   then advance; RetryNode.new(l, c)
      when TokenKind::KwAlias   then parse_alias
      when TokenKind::KwRequire then parse_require
      when TokenKind::KwYield   then parse_yield
      when TokenKind::KwSuper   then parse_super
      else
        parse_expr_statement
      end
    end

    # `begin...end while cond` / `begin...end until cond` (the do-while
    # form — see UNSUPPORTED.md, U016) as a BARE statement (no
    # assignment: `begin...end while cond` on its own, by far the more
    # natural way to write this) never reaches compile_modifier_while's
    # own U016 check at all: parse_statement's `KwBegin` case calls
    # parse_begin directly and, before this guard existed, returned
    # its bare BeginNode immediately — the trailing `while`/`until`
    # was left dangling as what LOOKED like the start of a totally
    # separate next statement, which the parser then reported as an
    # unrelated, confusing "`while` is missing its `end`" (P003) with
    # no hint that begin/rescue/ensure had anything to do with it.
    # Found 2026-08-05 by the first tests in this repo's history to
    # exercise this form at all.
    #
    # Deliberately does NOT build a ModifierWhile here the way a
    # genuine parse (rather than a rejection) would need to — this
    # form is never going to compile successfully, so there's
    # nothing to hand off to compile_modifier_while's own check; this
    # is simply the earlier of the two places that can recognize the
    # shape (a `begin` immediately followed by while/until) and
    # produce the same U016 with a precise span, rather than route
    # through the assignment form's ModifierWhile detour just to reach
    # a check with an identical outcome. `x = begin...end while cond`
    # (the assigned form) still reaches compile_modifier_while's own
    # U016 instead — this helper only covers the bare-statement
    # form parse_statement's KwBegin case is responsible for.
    private def reject_do_while(node : Node) : Node
      if at_any?(TokenKind::KwWhile, TokenKind::KwUntil)
        raise ParseError.new(
          Diagnostic.new(
            code: "U016",
            primary: Span.new(
              line: node.line,
              column: node.column,
              length: 5, # "begin"
              label: "do-while form not supported"
            )
          )
        )
      end
      node
    end

    # An expression that may be followed by a modifier (if/unless/while/until).
    # Modifiers are checked AFTER assignment so `x -= 1 while x > 0` works.
    private def parse_expr_statement : Node
      expr = parse_expression(0)
      # A comma here can't mean anything else at statement level — the
      # Pratt parser already stops `parse_expression` short of `,` (it
      # carries no PRECEDENCE entry), so seeing one now means a
      # multi-target assignment's target list (`a, b = ...`), not some
      # other comma-bearing construct. Committing on sight (no
      # backtracking) mirrors `parse_multi_rhs` below doing the same
      # thing on the rhs side.
      result = at_kind?(TokenKind::Comma) ? parse_multi_assign(expr) : maybe_assignment(expr)
      l, c = result.line, result.column
      case current_kind
      when TokenKind::KwIf
        advance
        ModifierIf.new(parse_expression(0), result, false, l, c)
      when TokenKind::KwUnless
        advance
        ModifierIf.new(parse_expression(0), result, true, l, c)
      when TokenKind::KwWhile
        advance
        ModifierWhile.new(parse_expression(0), result, false, l, c)
      when TokenKind::KwUntil
        advance
        ModifierWhile.new(parse_expression(0), result, true, l, c)
      else
        result
      end
    end

    # Resolve assignment if expr is a valid lvalue and = follows.
    private def maybe_assignment(lhs : Node) : Node
      l, c = lhs.line, lhs.column
      case current_kind
      when TokenKind::Eq
        advance
        rhs = parse_multi_rhs
        # Registered AFTER rhs parses, not before — matches real Ruby's
        # own `x = x` behavior (an as-yet-unassigned `x` on the RHS of
        # its own first assignment is still a bare call/undefined-name
        # reference, not a read of a not-yet-existing local; see the
        # local-tracking design comment near @local_scopes above).
        register_local_if_identifier(lhs)
        Assign.new(lhs, rhs, l, c)
      when TokenKind::PlusEq, TokenKind::MinusEq, TokenKind::StarEq,
           TokenKind::SlashEq, TokenKind::PercentEq
        op = advance.kind
        base_op = compound_base_op(op)
        rhs = parse_expression(0)
        register_local_if_identifier(lhs)
        OpAssign.new(base_op, lhs, rhs, l, c)
      when TokenKind::OrAssign, TokenKind::AndAssign
        op = advance.kind
        rhs = parse_expression(0)
        register_local_if_identifier(lhs)
        CondAssign.new(op, lhs, rhs, l, c)
      else
        lhs
      end
    end

    # Parse the remainder of a multi-target assignment once a `,` has
    # been seen after the first already-parsed target. Lvalue-ness
    # isn't checked here — same as the single-target path, that's left
    # to `emit_store` at compile time (C001), so `1, 2 = 3, 4` fails
    # there rather than here, consistent with how `1 = 2` already
    # behaves.
    private def parse_multi_assign(first : Node) : Node
      l, c = first.line, first.column
      targets = [first] of Node
      while match(TokenKind::Comma)
        targets << parse_expression(0)
      end
      expect(TokenKind::Eq)
      rhs = parse_multi_rhs
      values = rhs.is_a?(ArrayLiteral) ? rhs.elements : [rhs]
      targets.each { |target| register_local_if_identifier(target) }
      MultiAssign.new(targets, values, l, c)
    end

    private def compound_base_op(op : TokenKind) : TokenKind
      case op
      when TokenKind::PlusEq    then TokenKind::Plus
      when TokenKind::MinusEq   then TokenKind::Minus
      when TokenKind::StarEq    then TokenKind::Star
      when TokenKind::SlashEq   then TokenKind::Slash
      when TokenKind::PercentEq then TokenKind::Percent
      else                           op
      end
    end

    # Parse a comma-separated rhs; wraps in MultiAssign if needed.
    private def parse_multi_rhs : Node
      first = parse_expression(0)
      return first unless at_kind?(TokenKind::Comma)
      values = [first] of Node
      while match(TokenKind::Comma)
        values << parse_expression(0)
      end
      # Wrap as an array literal used as multi-rhs
      ArrayLiteral.new(values, first.line, first.column)
    end

    # --- Pratt expression parser --------------------------------------------

    PRECEDENCE = {
      TokenKind::Question  => 1,
      TokenKind::KwOr      => 2,
      TokenKind::OrOr      => 2,
      TokenKind::KwAnd     => 3,
      TokenKind::AndAnd    => 3,
      TokenKind::EqEq      => 4,
      TokenKind::NEq       => 4,
      TokenKind::Lt        => 5,
      TokenKind::LtE       => 5,
      TokenKind::Gt        => 5,
      TokenKind::GtE       => 5,
      TokenKind::Spaceship => 5,
      TokenKind::RangeIncl => 6,
      TokenKind::RangeExcl => 6,
      TokenKind::Pipe      => 7,
      TokenKind::Caret     => 7,
      TokenKind::Amp       => 7,
      TokenKind::Shl       => 8,
      TokenKind::Shr       => 8,
      TokenKind::Plus      => 9,
      TokenKind::Minus     => 9,
      TokenKind::Star      => 10,
      TokenKind::Slash     => 10,
      TokenKind::Percent   => 10,
    }

    private def token_precedence(kind : TokenKind) : Int32
      PRECEDENCE[kind]? || 0
    end

    private def parse_expression(min_prec : Int32) : Node
      left = parse_unary
      loop do
        # See @no_pipe's own comment — while armed, a `Pipe` here is
        # the closing delimiter of an enclosing block-param list, not
        # a bitwise-or continuing this expression, regardless of what
        # min_prec would otherwise allow through.
        break if @no_pipe && current_kind == TokenKind::Pipe
        prec = token_precedence(current_kind)
        break if prec <= min_prec
        op_tok = @current

        if op_tok.kind == TokenKind::Question
          advance
          then_expr = parse_expression(0)
          expect(TokenKind::Colon)
          else_expr = parse_expression(0)
          left = Ternary.new(left, then_expr, else_expr, op_tok.line, op_tok.column)
          next
        end

        if op_tok.kind == TokenKind::RangeIncl || op_tok.kind == TokenKind::RangeExcl
          advance
          right = parse_expression(prec)
          left = RangeLiteral.new(left, right, op_tok.kind == TokenKind::RangeExcl, op_tok.line, op_tok.column)
          next
        end

        advance
        right = parse_expression(prec)
        left = Binary.new(op_tok.kind, left, right, op_tok.line, op_tok.column)
      end
      left
    end

    private def parse_unary : Node
      l, c = line, col
      case current_kind
      when TokenKind::Bang
        op = advance.kind
        Unary.new(op, parse_unary, l, c)
      when TokenKind::Minus
        minus_l, minus_c = line, col
        advance
        # Fuse `-` with an IMMEDIATELY ADJACENT (no space) numeric
        # literal into a single negative-literal node, rather than the
        # general Unary-wraps-postfix path below. This is NOT a general
        # "unary minus binds tighter than postfix" rule — it would be
        # WRONG to apply this whenever the operand happens to be a
        # literal AST-node-shape; it specifically requires no
        # whitespace between the `-` and the digit, mirroring Ruby's
        # actual lexer-level `tUMINUS_NUM` token (confirmed empirically
        # 2026-07-25: `-0.0.to_s` → "-0.0" (fused), `- 0.0.to_s` → the
        # unary-operator-on-a-call form). `advance` above already
        # consumed the `-`, so `@current` is now the literal token
        # itself — its own `space_before?` (see `Token#space_before?`,
        # set by the lexer) directly answers "was there space right
        # before this token," no column arithmetic needed. Every other
        # unary-minus target (a variable, a call result, a
        # parenthesized expression, OR a numeric literal with a space
        # after the `-`) still goes through the ordinary
        # Unary-wraps-postfix path below, unchanged — see SCOPE.md's
        # entry on this fix for the full research trail (Ruby core bug
        # #19583, parse.y's own tUMINUS_NUM grammar rule).
        if (current_kind == TokenKind::Integer || current_kind == TokenKind::Float) && !@current.space_before?
          lit_tok = advance
          negated_lexeme = "-" + lit_tok.lexeme
          literal = if lit_tok.kind == TokenKind::Integer
                      IntLiteral.new(negated_lexeme, minus_l, minus_c)
                    else
                      FloatLiteral.new(negated_lexeme, minus_l, minus_c)
                    end
          parse_postfix(literal)
        else
          Unary.new(TokenKind::Minus, parse_unary, minus_l, minus_c)
        end
      when TokenKind::Plus
        # Same precedence tier as Bang (real Ruby: `!`, `~`, unary `+`
        # are all the single highest-precedence tier — see
        # docs.ruby-lang.org/en/3.3/syntax/precedence_rdoc.html). NOT
        # given the same literal-fusion treatment TokenKind::Minus
        # gets elsewhere for `-<literal>`: there's no such thing as a
        # "positive literal" AST node in Ruby (`+1` is just `1`'s
        # ordinary parse, with a real but no-op-for-numerics unary `+`
        # wrapped around it) — this is a genuinely simpler case than
        # unary minus, not a smaller version of the same fix.
        op = advance.kind
        Unary.new(op, parse_unary, l, c)
      when TokenKind::Tilde
        op = advance.kind
        Unary.new(op, parse_unary, l, c)
      when TokenKind::KwNot
        advance
        Unary.new(TokenKind::Bang, parse_unary, l, c)
      else
        parse_postfix(parse_primary)
      end
    end

    # --- Postfix: method calls, indexing, safe navigation ------------------

    private def parse_postfix(node : Node) : Node
      loop do
        l, c = line, col
        case current_kind
        when TokenKind::Dot, TokenKind::SafeNav
          safe = current_kind == TokenKind::SafeNav
          advance
          method_tok = @current
          advance
          args, kwargs, blk = parse_call_args_and_block
          node = Call.new(node, method_tok.lexeme, args, blk, safe, l, c, kwargs: kwargs)
        when TokenKind::ColonColon
          advance
          name_tok = @current
          advance
          if name_tok.kind == TokenKind::Constant
            node = ConstPath.new(node, name_tok.lexeme, l, c)
          else
            node = Call.new(node, name_tok.lexeme, [] of Node, nil, false, l, c)
          end
        when TokenKind::LBracket
          advance
          idx = parse_expression(0)
          expect(TokenKind::RBracket)
          safe = false
          if at_kind?(TokenKind::Eq)
            advance
            val = parse_expression(0)
            node = IndexAssign.new(node, idx, val, l, c)
          else
            node = Index.new(node, idx, safe, l, c)
          end
        else
          break
        end
      end
      node
    end

    # --- Primary expressions -----------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    private def parse_primary : Node
      l, c = line, col
      case current_kind
      when TokenKind::ColonColon
        advance
        name_tok = @current
        advance
        ConstPath.new(TopLevel.new(l, c), name_tok.lexeme, l, c)
      when TokenKind::KwNil
        advance
        NilLiteral.new(l, c)
      when TokenKind::KwTrue
        advance
        BoolLiteral.new(true, l, c)
      when TokenKind::KwFalse
        advance
        BoolLiteral.new(false, l, c)
      when TokenKind::KwSelf
        advance
        SelfNode.new(l, c)
      when TokenKind::KwMethodName, TokenKind::KwCalleeName
        advance
        MethodName.new(l, c)
      when TokenKind::Integer
        tok = advance
        IntLiteral.new(tok.lexeme, l, c)
      when TokenKind::Float
        tok = advance
        FloatLiteral.new(tok.lexeme, l, c)
      when TokenKind::String
        tok = advance
        StringLiteral.new(strip_quotes(tok.lexeme), l, c)
      when TokenKind::StringPart
        parse_interp_string(l, c)
      when TokenKind::Symbol
        tok = advance
        SymbolLiteral.new(tok.lexeme.lstrip(':').strip('"').strip('\''), l, c)
      when TokenKind::Identifier
        parse_identifier_or_call(l, c)
      when TokenKind::Constant
        tok = advance
        Constant.new(tok.lexeme, l, c)
      when TokenKind::IVar
        tok = advance
        IVar.new(tok.lexeme, l, c)
      when TokenKind::CVar
        tok = advance
        CVar.new(tok.lexeme, l, c)
      when TokenKind::LParen
        advance
        skip_newlines
        expr = parse_expression(0)
        skip_newlines
        expect(TokenKind::RParen)
        expr
      when TokenKind::LBracket
        parse_array_literal(l, c)
      when TokenKind::LBrace
        parse_hash_or_block_brace(l, c)
      when TokenKind::Arrow
        parse_lambda(l, c)
      when TokenKind::KwIf
        parse_if
      when TokenKind::KwUnless
        parse_unless
      when TokenKind::KwCase
        parse_case
      when TokenKind::KwBegin
        parse_begin
      when TokenKind::KwRaise
        parse_raise(l, c)
      else
        raise ParseError.new(
          Diagnostic.new(
            code: "P002",
            primary: Span.new(
              line: l,
              column: c,
              length: caret_width(@current),
              label: "not valid here"
            ),
            data: {"found" => describe_token(@current)}
          )
        )
      end
    end

    # True when @current is a Minus or Plus token that starts a bare
    # call's first argument rather than a binary operator — i.e. space
    # BEFORE the operator but NOT after it (`eq -1`, `eq +1`). Extracted
    # from `parse_identifier_or_call`'s own dispatch chain specifically
    # to keep that method's cyclomatic complexity under Ameba's
    # threshold (flagged once this condition grew a second clause,
    # `@current.space_before?`, alongside `operand_immediately_follows?`
    # — see this method's own full research trail, moved here
    # unchanged, for why BOTH conditions are required and not just the
    # second one).
    #
    # Two conditions, not one: `@current.space_before?` (space BEFORE
    # the operator) AND `operand_immediately_follows?` (no space AFTER
    # it). An earlier version of this check used only the second
    # condition, which happened to work for every case this arc's specs
    # covered (`eq -1`, `a - b`, `n - 1`) but was WRONG for `a-b`/`a+b`
    # — no space anywhere — which real Ruby parses as ordinary
    # Binary(a, -, b), not as a bare call `a(-b)`. That gap went
    # undetected until `spec/scripts/methods.rb`'s `def self.add(a,b);
    # a+b; end` (an existing test script, not new coverage written for
    # this fix) failed with R008, undefined method or variable `a` — `a+b`
    # was being parsed as `a(+b)`, a bare call passing `+b` as an
    # argument, so `a` (a real local parameter) was looked up as a
    # callable instead. Confirmed via real Ruby that `a-b`/`a+b` (no
    # space at all) is unambiguously binary, same as `a - b`/`a + b`
    # (space on both sides) — the ONLY shape that means "bare call,
    # first arg is a signed literal" is space-before-but-not-after,
    # exactly what both conditions together require.
    #
    # known_local? (the disambiguator that already correctly resolves
    # the `name [expr]` ambiguity in `parse_identifier_or_call`) does
    # NOT work here — tried first for the Minus case, then caught via a
    # failing pre-existing spec before shipping: `a + b` with `a` NOT a
    # known local still must parse as Binary, not `a(+b)`. Confirmed
    # precisely via `irb`: `def a; 999; end; def b; 111; end; p a + b`
    # → `1110` (calls BOTH a and b with zero args, THEN adds) — binary,
    # even though neither `a` nor `b` is a known local OR literal. Also
    # `def a; 999; end; p a -1` → `ArgumentError: given 1, expected 0`
    # — proving THIS specifically parsed as `a(-1)`, a call taking one
    # argument, even though `a` is a zero-arg method with no special
    # local-status either. The only structural difference between the
    # two: `a - b`'s operand is a bare identifier (space on both sides
    # of `-`); `a -1`'s operand is a literal IMMEDIATELY ADJACENT to
    # the operator (no space between `-` and `1`, though there IS a
    # space between `a` and `-`). The same structural distinction, and
    # the same fix, applies to `+` — Ruby's own unary-vs-binary
    # ambiguity for `+` follows the identical adjacency rule as `-`
    # (both are covered by the same "space before but not after"
    # warning class in Ruby's own parser), so this is one rule with two
    # operators, not two rules — sharing one predicate (rather than
    # duplicating it per-operator) is itself confirmation that Plus
    # needed no bespoke logic of its own once the real (adjacency, not
    # known_local?) rule was found.
    #
    # So the real rule is adjacency ON BOTH SIDES, not known_local? —
    # confirmed via Ruby's own "`-' after local variable or literal is
    # interpreted as binary operator, even though it seems like unary
    # operator" warning (bugs.ruby-lang.org), which fires precisely for
    # the space-before-but-not-after shape and documents that Ruby's
    # default in that case is BINARY (and, by the same logic Ruby
    # applies elsewhere, a no-space-at-all shape is unambiguously
    # binary too — there is no bare-call reading of `a-b` in real Ruby
    # at all). `eq -1`/`eq +1`: space before the operator, none between
    # the operator and the literal → bare-call start. `n - 1`/`a -
    # b`/`a-b`/`a+b`: NOT (space-before AND no-space-after) → this
    # returns false, so `parse_identifier_or_call` falls all the way
    # through to its own final `else` (`arg_follows_no_paren?` also
    # still rejects a bare Minus/Plus regardless of spacing — see its
    # own comment) — returning a plain Identifier and letting
    # parse_expression's own operator-precedence loop see the `-`/`+`
    # as binary, same as any other binary operator following a
    # variable or call-result reference.
    private def signed_literal_starts_bare_call? : Bool
      (at_kind?(TokenKind::Minus) || at_kind?(TokenKind::Plus)) &&
        @current.space_before? && operand_immediately_follows?
    end

    # Bare identifier — may be a local variable, a bare method call, or
    # a keyword-like call (puts, require handled in parse_statement).
    private def parse_identifier_or_call(l : Int32, c : Int32) : Node
      tok = advance
      name = tok.lexeme
      if at_kind?(TokenKind::LParen) && !@current.space_before?
        # `name(...)` — no space before `(` means THIS paren is name's
        # own call-argument-list syntax. Deliberately excludes the
        # space-before-`(` case (`name (...)`, handled by falling
        # through to `arg_follows_no_paren?` below, which allows
        # LParen unconditionally as an argument-start token) — a space
        # before `(` means the parenthesized expression is the bare
        # call's first ARGUMENT, not name's own arg-list delimiter.
        # `eq (6/3), 2` was previously misparsed because this check had
        # no lookahead beyond "is the current token `(`" at all: it
        # unconditionally treated ANY following `(` as `eq`'s own
        # call-syntax, so `parse_call_args_and_block` parsed `6/3` as
        # arg one, hit the closing `)` (from eq's perspective, the
        # wrong `)`), then choked on the bare `,` that followed with
        # nowhere to go. Confirmed via Ruby's own issue tracker
        # (bugs.ruby-lang.org/issues/20922) that `assert_equal (-1),
        # minus_one` — the same shape as this bug — is valid, WORKING
        # Ruby; separately confirmed (ruby-forum.com, "Space before
        # parentheses leads to syntax error") that a space before `(`
        # on a call with NO other args and a multi-value paren group
        # (`additionner (2,7)`) IS a syntax error, because `(2,7)`
        # isn't a valid single parenthesized expression the way
        # `(6/3)`/`(-1)` each are — this fix doesn't need to
        # distinguish those two cases itself, since `(2,7)` already
        # fails on its own merits once parsed as a bare call's first
        # argument (a bare tuple isn't a valid expression here either).
        # See SCOPE.md's entry on this bug for the full research trail.
        args, kwargs, blk = parse_call_args_and_block
        Call.new(nil, name, args, blk, false, l, c, kwargs: kwargs)
      elsif block_follows_no_paren?
        blk = parse_block
        Call.new(nil, name, [] of Node, blk, false, l, c)
      elsif at_kind?(TokenKind::LBracket)
        # `name [expr]` — genuinely ambiguous between indexing an
        # existing local (`Index` node, handled by parse_postfix once
        # we fall through to a bare Identifier below) and a bare call
        # taking an array literal as its first argument (`Call` node
        # with an ArrayLiteral arg). Real Ruby's parser resolves this
        # itself: a name that was already established as a local
        # ALWAYS means indexing from that point on, regardless of what
        # it holds at runtime; an unestablished name ALWAYS means a
        # call, even if no such method actually exists either — it
        # just fails at runtime instead of at parse time (confirmed via
        # a series of `irb` experiments, incl. `c = 5; c [1]` → 0 via
        # Integer#[], `d = true; d [1]` → NoMethodError not a parse
        # error, and `totally_undefined [1,2,3]` → NoMethodError for
        # 'totally_undefined', proving it parsed as a CALL even though
        # no such method or variable exists — see 2026-07-21's design
        # conversation for the full trace). `known_local?` (see
        # @local_scopes above) is this parser's own lightweight,
        # syntax-only echo of that same rule.
        known_local?(name) ? Identifier.new(name, l, c) : parse_bare_call_args(name, l, c)
      elsif signed_literal_starts_bare_call?
        # `name -expr` / `name +expr` — genuinely ambiguous between a
        # BINARY operator (`n - 1`, `a - b`, `n + 1`) and the start of a
        # bare call's first argument (`eq -1, -1`, `eq +1, -1`). See
        # `signed_literal_starts_bare_call?`'s own comment for the full
        # research trail (extracted there, unchanged, to keep this
        # method's cyclomatic complexity under Ameba's threshold).
        parse_bare_call_args(name, l, c)
      elsif arg_follows_no_paren?
        # bare call: `puts x`, `raise "msg"`, etc.
        parse_bare_call_args(name, l, c)
      else
        Identifier.new(name, l, c)
      end
    end

    # Shared tail for every bare-(no-paren)-call shape above: parse a
    # comma-separated argument list via `parse_expression`, then an
    # optional trailing block. Factored out specifically to reduce
    # `parse_identifier_or_call`'s cyclomatic complexity (flagged by
    # Ameba after this method grew a third near-identical branch this
    # session) — this was pure duplication, not three independent
    # behaviors, so extracting it is a genuine simplification, not just
    # a lint workaround.
    private def parse_bare_call_args(name : String, l : Int32, c : Int32) : Call
      args = [] of Node
      kwargs = [] of {String, Node}
      parse_call_arg(args, kwargs)
      while match(TokenKind::Comma)
        parse_call_arg(args, kwargs)
      end
      blk = parse_block if block_follows_no_paren?
      Call.new(nil, name, args, blk, false, l, c, kwargs: kwargs)
    end

    private def block_follows_no_paren? : Bool
      return at_kind?(TokenKind::LBrace) if @no_do_block
      at_any?(TokenKind::KwDo, TokenKind::LBrace)
    end

    # True when the current token unambiguously starts an argument in a
    # bare (no-paren) call position. We use a positive allowlist rather
    # than a blocklist so that binary operators, postfix tokens, and
    # terminators are never mistaken for argument starts.
    #
    # Allowed: literals, identifiers, constants, variables, unary prefix
    # operators (-, !, ~), opening delimiters (including `[`, an array
    # literal), and keyword literals.
    #
    # `LBracket` is safe to allow unconditionally HERE — unlike
    # `parse_identifier_or_call`'s own `name [...]` case (handled by its
    # own dedicated known_local? branch above `arg_follows_no_paren?`'s
    # call there, precisely BECAUSE that one case is genuinely
    # ambiguous), this method is only ever reached from `raise`/`super`
    # (parse_raise, parse_super) — both keyword tokens, never possibly a
    # variable name, so `raise [1,2,3]`/`super [1,2,3]` can only ever
    # mean "call with an array-literal argument," no indexing
    # interpretation is even grammatically possible.
    private def arg_follows_no_paren? : Bool
      case current_kind
      when TokenKind::Integer, TokenKind::Float,
           TokenKind::String, TokenKind::StringPart,
           TokenKind::Symbol, TokenKind::KwSelf,
           TokenKind::KwNil, TokenKind::KwTrue, TokenKind::KwFalse,
           TokenKind::Bang, TokenKind::Tilde,
           TokenKind::LParen, TokenKind::LBracket,
           TokenKind::Identifier, TokenKind::Constant
        true
      when TokenKind::Minus
        # Correctly false HERE — Minus (and, since the unary-`+`
        # fix, Plus too) is handled entirely by
        # parse_identifier_or_call's own dedicated, adjacency-aware
        # branch above (checked BEFORE this method is ever consulted
        # for that call site), which needs to distinguish `eq -1`
        # (bare-call start) from `n - 1`/`a - b` (binary) — a
        # distinction this method has no way to make on its own, since
        # it only sees a token kind, not the surrounding whitespace
        # context now captured on `Token#space_before?`. `raise -1`
        # (this method's OTHER call site, parse_raise) is consequently
        # also not yet supported — `raise` is a keyword with no such
        # ambiguity to resolve, so it COULD safely allow Minus (and
        # Plus) unconditionally, but that's a separate, smaller,
        # not-yet-reported gap, deliberately left alone here to keep
        # this fix scoped to what was actually asked (see SCOPE.md).
        false
      else
        false
      end
    end

    # --- Calls --------------------------------------------------------------

    # One call argument: `name: value` (an Identifier immediately
    # followed by a Colon, checked via one-token lookahead so it
    # doesn't misfire on a ternary's `cond ? a : b`, whose colon is
    # never the SECOND token of an argument) routes into `kwargs`;
    # everything else is an ordinary positional expression. Shared
    # between the parenthesized and bare (no-paren) call-argument
    # loops so this lookahead lives in exactly one place.
    private def parse_call_arg(args : Array(Node), kwargs : Array({String, Node})) : Nil
      if at_kind?(TokenKind::Identifier) && peek_kind == TokenKind::Colon
        name = advance.lexeme
        advance # the Colon
        kwargs << {name, parse_expression(0)}
      else
        args << parse_expression(0)
      end
    end

    private def parse_call_args_and_block : {Array(Node), Array({String, Node}), BlockNode?}
      args = [] of Node
      kwargs = [] of {String, Node}
      blk = nil
      if at_kind?(TokenKind::LParen)
        advance
        skip_newlines
        unless at_kind?(TokenKind::RParen)
          parse_call_arg(args, kwargs)
          while match(TokenKind::Comma)
            skip_newlines
            break if at_kind?(TokenKind::RParen)
            parse_call_arg(args, kwargs)
          end
        end
        skip_newlines
        expect(TokenKind::RParen)
      end
      blk = parse_block if block_follows_no_paren?
      {args, kwargs, blk}
    end

    private def parse_block : BlockNode
      # Suspended for this WHOLE block literal (params AND body), not
      # just its params — see @no_pipe's own comment. Reachable with
      # @no_pipe already true when this block is written as the
      # default value of an ENCLOSING param (`def f(g = xs.each { |y|
      # y })`): without suspending here, the outer flag would still be
      # armed while parsing THIS block's own `|y|` and body, breaking
      # both a bare `|` inside this block's body and (were block
      # params ever nested two default-levels deep) this block's own
      # param defaults. Saved/restored, not reset to a hardcoded
      # false, so a block literal directly inside another block
      # literal's default (however unlikely) still nests correctly.
      saved_no_pipe = @no_pipe
      @no_pipe = false
      begin
        l, c = line, col
        push_local_scope(inherit: true)
        if at_kind?(TokenKind::KwDo)
          open_block("do", line, col)
          advance
          params = parse_block_params
          params.each { |param| register_local(param.name) }
          skip_newlines
          body = parse_body_until(TokenKind::KwEnd)
          close_block
          pop_local_scope
          BlockNode.new(params, body, l, c)
        else
          expect(TokenKind::LBrace)
          params = parse_block_params
          params.each { |param| register_local(param.name) }
          skip_newlines
          body = parse_body_until(TokenKind::RBrace)
          expect(TokenKind::RBrace)
          pop_local_scope
          BlockNode.new(params, body, l, c)
        end
      ensure
        @no_pipe = saved_no_pipe
      end
    end

    private def parse_block_params : Array(Param)
      return [] of Param unless at_kind?(TokenKind::Pipe)
      advance
      params = [] of Param
      until at_kind?(TokenKind::Pipe)
        params << parse_param
        break unless match(TokenKind::Comma)
      end
      expect(TokenKind::Pipe)
      params
    end

    # --- Literals -----------------------------------------------------------

    private def parse_interp_string(l : Int32, c : Int32) : Node
      parts = [] of Node
      while at_kind?(TokenKind::StringPart)
        tok = advance
        parts << StringFragment.new(tok.lexeme, tok.line, tok.column)
        # parse the interpolated expression until InterpEnd
        skip_newlines
        until at_kind?(TokenKind::InterpEnd) || at_kind?(TokenKind::EOF)
          parts << parse_expression(0)
          skip_terminators
        end
        expect(TokenKind::InterpEnd)
      end
      if at_kind?(TokenKind::StringEnd)
        tok = advance
        parts << StringFragment.new(tok.lexeme, tok.line, tok.column) unless tok.lexeme.empty?
      end
      InterpString.new(parts, l, c)
    end

    private def parse_array_literal(l : Int32, c : Int32) : Node
      expect(TokenKind::LBracket)
      elements = [] of Node
      skip_newlines
      until at_kind?(TokenKind::RBracket) || at_kind?(TokenKind::EOF)
        elements << parse_expression(0)
        skip_newlines
        break unless match(TokenKind::Comma)
        skip_newlines
      end
      expect(TokenKind::RBracket)
      ArrayLiteral.new(elements, l, c)
    end

    private def parse_hash_or_block_brace(l : Int32, c : Int32) : Node
      # Heuristic: if after { we see key => or key: treat as hash, else block
      # For now parse as hash literal; standalone braces without a call context
      # will be caught as a block by parse_identifier_or_call.
      expect(TokenKind::LBrace)
      pairs = [] of {Node, Node}
      skip_newlines
      until at_kind?(TokenKind::RBrace) || at_kind?(TokenKind::EOF)
        key = parse_expression(0)
        expect(TokenKind::HashRocket)
        val = parse_expression(0)
        pairs << {key, val}
        skip_newlines
        break unless match(TokenKind::Comma)
        skip_newlines
      end
      expect(TokenKind::RBrace)
      HashLiteral.new(pairs, l, c)
    end

    # --- Definitions --------------------------------------------------------

    private def parse_def : DefNode
      l, c = line, col
      open_block("def", l, c)
      expect(TokenKind::KwDef)
      recv = nil
      name_tok = @current
      advance
      # Check for def obj.method / def self.method
      if at_kind?(TokenKind::Dot)
        advance
        recv = if name_tok.kind == TokenKind::KwSelf
                 SelfNode.new(name_tok.line, name_tok.column)
               else
                 Identifier.new(name_tok.lexeme, name_tok.line, name_tok.column)
               end
        name_tok = @current
        advance
      end
      push_local_scope(inherit: false)
      params = [] of Param
      if at_kind?(TokenKind::LParen)
        advance
        params = parse_param_list
        expect(TokenKind::RParen)
      end
      params.each { |param| register_local(param.name) }
      skip_terminators
      body = parse_body_until(TokenKind::KwEnd)
      close_block
      pop_local_scope
      DefNode.new(name_tok.lexeme, recv, params, body, l, c)
    end

    private def parse_param_list : Array(Param)
      params = [] of Param
      until at_kind?(TokenKind::RParen) || at_kind?(TokenKind::EOF)
        params << parse_param
        break unless match(TokenKind::Comma)
      end
      params
    end

    private def parse_param : Param
      l, c = line, col
      if at_kind?(TokenKind::Star)
        advance
        name = @current.lexeme
        advance
        return Param.new(name, nil, true, false, false, l, c)
      end
      if at_kind?(TokenKind::Amp)
        advance
        name = @current.lexeme
        advance
        return Param.new(name, nil, false, true, false, l, c)
      end
      name = @current.lexeme
      advance
      # keyword argument: name: or name: default
      if at_kind?(TokenKind::Colon)
        advance
        # The `at_any?` guard only covers an EMPTY default (`name:`
        # immediately followed by `,`/`)`/`|`) — a non-trivial kwarg
        # default (`name: 9`) still needs the same @no_pipe protection
        # as an ordinary default just below, for the identical reason:
        # `Pipe` closing a block's param list is otherwise
        # indistinguishable from `Pipe` continuing the default
        # expression as bitwise-or. Kwarg call-site syntax isn't
        # implemented yet (see SCOPE.md's Must Fix), but kwarg
        # DECLARATION on a block param is — `xs.each { |k: 9| k }` —
        # so this is a live path, not dead code.
        default = if at_any?(TokenKind::Comma, TokenKind::RParen, TokenKind::Pipe)
                    nil
                  else
                    begin
                      @no_pipe = true
                      parse_expression(0)
                    ensure
                      @no_pipe = false
                    end
                  end
        return Param.new(name, default, false, false, true, l, c)
      end
      # default parameter: name = value
      if at_kind?(TokenKind::Eq)
        advance
        # @no_pipe is a no-op for a DEF param's default (no enclosing
        # `|...|`, so Pipe never appears at min_prec=0 here regardless)
        # — armed unconditionally anyway so this one code path is
        # correct for both def-params and block-params, rather than
        # branching parse_param itself on which kind of param list
        # called it.
        default = begin
          @no_pipe = true
          parse_expression(0)
        ensure
          @no_pipe = false
        end
        return Param.new(name, default, false, false, false, l, c)
      end
      Param.new(name, nil, false, false, false, l, c)
    end

    private def parse_class : ClassNode
      l, c = line, col
      open_block("class", l, c)
      expect(TokenKind::KwClass)
      name = @current.lexeme
      advance
      superclass = nil
      if at_kind?(TokenKind::Lt)
        advance
        superclass = @current.lexeme
        advance
      end
      skip_terminators
      push_local_scope(inherit: false)
      body = parse_body_until(TokenKind::KwEnd)
      pop_local_scope
      close_block
      ClassNode.new(name, superclass, body, l, c)
    end

    private def parse_module : ModuleNode
      l, c = line, col
      open_block("module", l, c)
      expect(TokenKind::KwModule)
      name = @current.lexeme
      advance
      skip_terminators
      push_local_scope(inherit: false)
      body = parse_body_until(TokenKind::KwEnd)
      pop_local_scope
      close_block
      ModuleNode.new(name, body, l, c)
    end

    private def parse_lambda(l : Int32, c : Int32) : Lambda
      expect(TokenKind::Arrow)
      push_local_scope(inherit: true)
      params = [] of Param
      if at_kind?(TokenKind::LParen)
        advance
        params = parse_param_list
        expect(TokenKind::RParen)
      end
      params.each { |param| register_local(param.name) }
      skip_newlines
      body = if at_kind?(TokenKind::LBrace)
               advance
               b = parse_body_until(TokenKind::RBrace)
               expect(TokenKind::RBrace)
               b
             else
               open_block("do", line, col)
               expect(TokenKind::KwDo)
               b = parse_body_until(TokenKind::KwEnd)
               close_block
               b
             end
      pop_local_scope
      Lambda.new(params, body, l, c)
    end

    # --- Control flow -------------------------------------------------------

    private def parse_if : IfNode
      l, c = line, col
      open_block("if", l, c)
      expect(TokenKind::KwIf)
      cond = parse_expression(0)
      skip_terminators
      then_branch = parse_body_until_any(TokenKind::KwElsif, TokenKind::KwElse, TokenKind::KwEnd)
      elsifs = [] of {Node, Body}
      while at_kind?(TokenKind::KwElsif)
        advance
        elsif_cond = parse_expression(0)
        skip_terminators
        elsif_body = parse_body_until_any(TokenKind::KwElsif, TokenKind::KwElse, TokenKind::KwEnd)
        elsifs << {elsif_cond, elsif_body}
      end
      else_branch = nil
      if match(TokenKind::KwElse)
        skip_terminators
        else_branch = parse_body_until(TokenKind::KwEnd)
      end
      close_block
      IfNode.new(cond, then_branch, elsifs, else_branch, l, c)
    end

    private def parse_unless : UnlessNode
      l, c = line, col
      open_block("unless", l, c)
      expect(TokenKind::KwUnless)
      cond = parse_expression(0)
      skip_terminators
      then_branch = parse_body_until_any(TokenKind::KwElse, TokenKind::KwEnd, TokenKind::KwEnd)
      else_branch = nil
      if match(TokenKind::KwElse)
        skip_terminators
        else_branch = parse_body_until(TokenKind::KwEnd)
      end
      close_block
      UnlessNode.new(cond, then_branch, else_branch, l, c)
    end

    private def parse_while(until_loop : Bool) : WhileNode
      l, c = line, col
      open_block("while", l, c)
      advance
      @no_do_block = true
      cond = begin
        parse_expression(0)
      ensure
        @no_do_block = false
      end
      skip_terminators
      # Optional trailing `do`, same as `for ... in ... do` — Ruby
      # allows (but doesn't require) `do` after a while/until
      # condition. Previously never consumed here at all, so
      # `while cond do` left `do` sitting as the next token and the
      # body parse failed on it immediately.
      if at_kind?(TokenKind::KwDo)
        advance
        skip_terminators
      end
      body = parse_body_until(TokenKind::KwEnd)
      close_block
      WhileNode.new(cond, body, until_loop, l, c)
    end

    private def parse_loop : LoopNode
      l, c = line, col
      expect(TokenKind::KwLoop)
      skip_terminators
      # loop do ... end or loop { ... }. Only the `do` form is closed
      # by an `end`, so only it is tracked — a `{ }` form can't produce
      # a missing-`end` diagnostic.
      if at_kind?(TokenKind::KwDo)
        open_block("loop", l, c)
        advance
        body = parse_body_until(TokenKind::KwEnd)
        close_block
      else
        expect(TokenKind::LBrace)
        body = parse_body_until(TokenKind::RBrace)
        expect(TokenKind::RBrace)
      end
      LoopNode.new(body, l, c)
    end

    private def parse_for : ForNode
      l, c = line, col
      open_block("for", l, c)
      expect(TokenKind::KwFor)
      vars = [] of String
      vars << @current.lexeme
      advance
      while match(TokenKind::Comma)
        vars << @current.lexeme
        advance
      end
      expect(TokenKind::KwIn)
      @no_do_block = true
      iter = begin
        parse_expression(0)
      ensure
        @no_do_block = false
      end
      # Registered into the CURRENT scope, not a new one — a for-loop
      # does not open its own scope in Ruby (the loop variable is a
      # real local, readable after the loop ends too), unlike a block
      # or lambda's `|x|` params.
      vars.each { |v| register_local(v) }
      skip_terminators
      if at_kind?(TokenKind::KwDo)
        advance
        skip_terminators
      end
      body = parse_body_until(TokenKind::KwEnd)
      close_block
      ForNode.new(vars, iter, body, l, c)
    end

    private def parse_case : CaseNode
      l, c = line, col
      open_block("case", l, c)
      expect(TokenKind::KwCase)
      subject = at_any?(TokenKind::Newline, TokenKind::Semi) ? nil : parse_expression(0)
      skip_terminators
      whens = [] of {Array(Node), Body}
      until at_any?(TokenKind::KwElse, TokenKind::KwEnd, TokenKind::EOF)
        expect(TokenKind::KwWhen)
        patterns = [parse_expression(0)] of Node
        while match(TokenKind::Comma)
          patterns << parse_expression(0)
        end
        skip_terminators
        match(TokenKind::KwThen)
        skip_terminators
        when_body = parse_body_until_any(TokenKind::KwWhen, TokenKind::KwElse, TokenKind::KwEnd)
        whens << {patterns, when_body}
      end
      else_branch = nil
      if match(TokenKind::KwElse)
        skip_terminators
        else_branch = parse_body_until(TokenKind::KwEnd)
      end
      close_block
      CaseNode.new(subject, whens, else_branch, l, c)
    end

    private def parse_return : Node
      l, c = line, col
      expect(TokenKind::KwReturn)
      value = at_any?(TokenKind::Newline, TokenKind::Semi, TokenKind::EOF) ? nil : parse_expression(0)
      result = ReturnNode.new(value, l, c)
      case current_kind
      when TokenKind::KwIf
        advance; ModifierIf.new(parse_expression(0), result, false, l, c)
      when TokenKind::KwUnless
        advance; ModifierIf.new(parse_expression(0), result, true, l, c)
      else
        result
      end
    end

    private def parse_break(node_class : BreakNode.class | NextNode.class) : Node
      l, c = line, col
      advance
      value = at_any?(TokenKind::Newline, TokenKind::Semi, TokenKind::EOF) ? nil : parse_expression(0)
      result = node_class.new(value, l, c)
      case current_kind
      when TokenKind::KwIf
        advance; ModifierIf.new(parse_expression(0), result, false, l, c)
      when TokenKind::KwUnless
        advance; ModifierIf.new(parse_expression(0), result, true, l, c)
      else
        result
      end
    end

    private def parse_yield : YieldNode
      l, c = line, col
      expect(TokenKind::KwYield)
      args = [] of Node
      if at_kind?(TokenKind::LParen)
        advance
        until at_kind?(TokenKind::RParen) || at_kind?(TokenKind::EOF)
          args << parse_expression(0)
          break unless match(TokenKind::Comma)
        end
        expect(TokenKind::RParen)
      elsif !at_any?(TokenKind::Newline, TokenKind::Semi, TokenKind::EOF, TokenKind::KwEnd)
        args << parse_expression(0)
        while match(TokenKind::Comma)
          args << parse_expression(0)
        end
      end
      YieldNode.new(args, l, c)
    end

    private def parse_super : SuperNode
      l, c = line, col
      expect(TokenKind::KwSuper)
      if at_kind?(TokenKind::LParen)
        advance
        args = [] of Node
        until at_kind?(TokenKind::RParen) || at_kind?(TokenKind::EOF)
          args << parse_expression(0)
          break unless match(TokenKind::Comma)
        end
        expect(TokenKind::RParen)
        SuperNode.new(args, false, l, c)
      elsif at_any?(TokenKind::Newline, TokenKind::Semi, TokenKind::EOF, TokenKind::KwEnd)
        SuperNode.new([] of Node, true, l, c)
      else
        args = [parse_expression(0)] of Node
        while match(TokenKind::Comma)
          args << parse_expression(0)
        end
        SuperNode.new(args, false, l, c)
      end
    end

    # `raise` is a keyword token (KwRaise), so it never reaches
    # parse_identifier_or_call's bare-call handling. Desugar to the same
    # Call shape (receiver nil, method "raise") so the existing native
    # "raise" builtin handles it unchanged. Supports `raise`, `raise "msg"`,
    # and `raise("msg")`.
    private def parse_raise(l : Int32, c : Int32) : Node
      advance # consume 'raise'
      args = [] of Node
      if at_kind?(TokenKind::LParen)
        args, _kwargs, _blk = parse_call_args_and_block
      elsif arg_follows_no_paren?
        args << parse_expression(0)
        while match(TokenKind::Comma)
          args << parse_expression(0)
        end
      end
      Call.new(nil, "raise", args, nil, false, l, c)
    end

    private def parse_begin : BeginNode
      l, c = line, col
      open_block("begin", l, c)
      expect(TokenKind::KwBegin)
      skip_terminators
      body = parse_body_until_any(TokenKind::KwRescue, TokenKind::KwEnsure, TokenKind::KwEnd)
      rescue_clauses = [] of RescueClause
      ensure_body = nil
      while match(TokenKind::KwRescue)
        classes = [] of Node
        rescue_var = nil
        if at_kind?(TokenKind::Constant)
          # Reuses the normal expression parser so `rescue Foo::Bar`
          # gets full constant-path support for free. `rescue A, B`
          # collects each comma-separated type into `classes`, tried
          # left-to-right (OR) against the raised error, same as real
          # Ruby.
          classes << parse_expression(0)
          while match(TokenKind::Comma)
            classes << parse_expression(0)
          end
          if match(TokenKind::HashRocket)
            rescue_var = @current.lexeme
            advance
          end
        elsif match(TokenKind::HashRocket)
          rescue_var = @current.lexeme
          advance
        elsif at_kind?(TokenKind::Identifier)
          # Legacy/bare form: `rescue e` binds a variable with no class
          # filter (catches everything) — kept for backward compat.
          rescue_var = @current.lexeme
          advance
        end
        skip_terminators
        # Registered into the CURRENT scope, not a new one — a rescue
        # clause does not open its own scope in Ruby (same reasoning
        # as the for-loop variable above; a rescue-bound variable
        # remains a real local after the whole begin/rescue/end too).
        rescue_var.try { |v| register_local(v) }
        rescue_body = parse_body_until_any(TokenKind::KwRescue, TokenKind::KwEnsure, TokenKind::KwEnd)
        rescue_clauses << RescueClause.new(classes, rescue_var, rescue_body)
      end
      if match(TokenKind::KwEnsure)
        skip_terminators
        ensure_body = parse_body_until(TokenKind::KwEnd)
      end
      close_block
      BeginNode.new(body, rescue_clauses, ensure_body, l, c)
    end

    private def parse_require : RequireNode
      l, c = line, col
      expect(TokenKind::KwRequire)
      path = parse_expression(0)
      RequireNode.new(path, l, c)
    end

    private def parse_alias : AliasNode
      l, c = line, col
      expect(TokenKind::KwAlias)
      new_name = @current.lexeme.lstrip(':')
      advance
      old_name = @current.lexeme.lstrip(':')
      advance
      AliasNode.new(new_name, old_name, l, c)
    end

    # --- Body helpers -------------------------------------------------------

    private def parse_body_until(stop : TokenKind) : Body
      l, c = line, col
      stmts = [] of Node
      skip_terminators
      until at_kind?(stop) || at_kind?(TokenKind::EOF)
        stmts << parse_statement
        skip_terminators
      end
      Body.new(stmts, l, c)
    end

    private def parse_body_until_any(a : TokenKind, b : TokenKind, c_kind : TokenKind) : Body
      l, c = line, col
      stmts = [] of Node
      skip_terminators
      until at_any?(a, b, c_kind) || at_kind?(TokenKind::EOF)
        stmts << parse_statement
        skip_terminators
      end
      Body.new(stmts, l, c)
    end

    # --- Utilities ----------------------------------------------------------

    private def strip_quotes(s : String) : String
      return s[1..-2] if s.size >= 2 && (s.starts_with?('"') || s.starts_with?('\''))
      s
    end
  end
end
