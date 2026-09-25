require "./token"
require "./lexer"
require "./ast"
require "./diagnostic"

module Adjutant
  class ParseError < Exception
    getter line : Int32
    getter column : Int32

    # The structured diagnostic; nil only for an error built from a
    # plain message.
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
    # While true, a bare `do` doesn't start a block. Set while parsing
    # a `for` iterable or a `while`/`until` condition, whose trailing
    # `do` belongs to the loop: `while i < a.size do ... end`.
    @no_do_block = false

    # While true, `|` ends the expression instead of meaning bitwise
    # or. Set while parsing a block parameter's default (`|x = 9|`)
    # and suspended inside a nested block. So `{ |x = (a | b)| }`
    # needs its parentheses.
    @no_pipe = false

    # The bare names known as locals in each open scope, used only to
    # parse `name [x]`: indexing if `name` is a local, otherwise a call
    # with an array argument, as in Ruby. A name becomes a local when
    # assigned or bound as a parameter, whatever it holds at runtime.
    #
    # A `def` pushes an empty scope; a block or lambda pushes a copy of
    # the enclosing one, so its new names don't leak out. A `for`
    # variable or `rescue => e` binding joins the current scope, since
    # neither opens one in Ruby.
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

    # Whether the current `-` or `+` touches the token after it
    # (`-1`, `-x`) rather than being spaced as a binary operator.
    private def operand_immediately_follows? : Bool
      !@next.space_before?
    end

    # Records `lhs` as a local if it's a bare identifier; other
    # assignment targets (`@x`, `a[0]`, `obj.attr`) introduce no name.
    private def register_local_if_identifier(lhs : Node) : Nil
      register_local(lhs.name) if lhs.is_a?(Identifier)
    end

    # A construct being parsed that needs an `end`, with the position
    # of its opening keyword, so a missing `end` can name it.
    record OpenBlock, kind : String, line : Int32, column : Int32

    def initialize(source : IO, filename : String = "<input>")
      @lexer = Lexer.new(source, filename)
      @current = @lexer.next_token
      @next = @lexer.next_token
    end

    # The source text, available before `parse` so a caller can
    # register it for rendering a ParseError.
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
        append_statement(stmts, parse_statement)
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

    # Open constructs, innermost last. Not popped on error: a
    # missing-`end` diagnostic needs the abandoned entry.
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

    # The error for expecting `expected` and finding the current
    # token. A missing `end` points at the construct left open.
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

      # A missing `end` with a known open construct is P003, not P001.
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

    # One column for EOF, which has no text.
    private def caret_width(token : Token) : Int32
      token.kind == TokenKind::EOF ? 1 : Math.max(1, token.lexeme.size)
    end

    # Token kinds as a script author would have typed them.
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
      when TokenKind::KwAttrReader, TokenKind::KwAttrWriter, TokenKind::KwAttrAccessor
        parse_attr(current_kind)
      else
        # `super` and `yield` go through the expression parser, so
        # `super + 4` and `x = yield` work at statement position.
        parse_expr_statement
      end
    end

    # Rejects a bare `begin...end while cond` (or `until`) with U016.
    # The assigned form, `x = begin...end while cond`, is rejected by
    # the compiler instead.
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
      # A `,` after a statement's first expression can only begin a
      # multiple assignment's target list: `a, b = ...`.
      result = at_kind?(TokenKind::Comma) ? parse_multi_assign(expr) : expr
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

    # If `lhs` is followed by `=` or a compound assignment, parses the
    # assignment and returns it; otherwise returns `lhs`. Assignment is
    # right-associative: `c = b = 5`.
    private def maybe_assignment(lhs : Node) : Node
      l, c = lhs.line, lhs.column
      case current_kind
      when TokenKind::Eq
        advance
        rhs = parse_multi_rhs
        # `recv.attr = value` is a call to `attr=`. A call with
        # arguments or a block isn't an attribute, and falls through to
        # Assign, which the compiler rejects (C001).
        if lhs.is_a?(Call) && (call = lhs.as(Call)) && (recv = call.receiver) &&
           call.args.empty? && call.kwargs.empty? && call.block.nil?
          return AttrAssign.new(recv, call.method, rhs, l, c)
        end
        # Registered after the right-hand side is parsed: in `x = x`,
        # the right-hand `x` is not yet a local, as in Ruby.
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

    # Parses the rest of a multiple assignment after its first target
    # and `,`. The compiler checks that targets are assignable (C001).
    # Targets are parsed without resolving `=`, which belongs to the
    # multiple assignment.
    private def parse_multi_assign(first : Node) : Node
      l, c = first.line, first.column
      targets = [first] of Node
      while match(TokenKind::Comma)
        skip_newlines
        targets << parse_expression(0, resolve_assignment: false)
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
        skip_newlines
        values << parse_expression(0)
      end
      # Wrap as an array literal used as multi-rhs
      ArrayLiteral.new(values, first.line, first.column)
    end

    # --- Pratt expression parser --------------------------------------------

    # Binding power of each binary operator; higher binds tighter.
    # Ruby puts `<=>` on the same tier as `==`, `=~` and `!~`; here it
    # sits one tier above.
    PRECEDENCE = {
      TokenKind::Question  => 1,
      TokenKind::KwOr      => 2,
      TokenKind::OrOr      => 2,
      TokenKind::KwAnd     => 3,
      TokenKind::AndAnd    => 3,
      TokenKind::EqEq      => 4,
      TokenKind::NEq       => 4,
      TokenKind::EqTilde   => 4,
      TokenKind::BangTilde => 4,
      TokenKind::TripleEq  => 4,
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

    # `=` and the compound assignments, which are resolved by
    # `maybe_assignment` rather than through `PRECEDENCE`.
    private def assignment_token?(kind : TokenKind) : Bool
      kind.in?(
        TokenKind::Eq, TokenKind::PlusEq, TokenKind::MinusEq, TokenKind::StarEq,
        TokenKind::SlashEq, TokenKind::PercentEq, TokenKind::OrAssign, TokenKind::AndAssign
      )
    end

    private def parse_expression(min_prec : Int32, resolve_assignment : Bool = true) : Node
      left = parse_unary
      # Assignment is resolved as soon as its target is parsed,
      # whatever `min_prec` is, since Ruby's grammar keys assignment on
      # the target: `7 == tot = sum(3, 4)` is `7 == (tot = sum(3, 4))`,
      # and `a + b = 1` is `a + (b = 1)`. `resolve_assignment: false`
      # is for a multiple assignment's targets.
      left = maybe_assignment(left) if resolve_assignment && assignment_token?(current_kind)
      loop do
        # A `|` closing a block parameter list; see `@no_pipe`.
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
          right = range_end_omitted? ? nil : parse_expression(prec)
          left = RangeLiteral.new(left, right, op_tok.kind == TokenKind::RangeExcl, op_tok.line, op_tok.column)
          next
        end

        advance
        skip_newlines
        right = parse_expression(prec)
        left = Binary.new(op_tok.kind, left, right, op_tok.line, op_tok.column)
      end
      left
    end

    # Whether the range's end is omitted (`1..`): the next token is a
    # closer, separator or terminator rather than an expression start,
    # as in `arr[2..]`, `when 18.. then` and `f(2..)`.
    private def range_end_omitted? : Bool
      at_any?(
        TokenKind::Newline, TokenKind::Semi, TokenKind::EOF, TokenKind::KwEnd,
        TokenKind::RParen, TokenKind::RBracket, TokenKind::RBrace,
        TokenKind::Comma, TokenKind::KwThen, TokenKind::KwDo
      )
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
        # `-` touching a numeric literal makes a negative literal, as
        # Ruby's lexer does: `-0.0.to_s` is "-0.0", while `- 0.0.to_s`
        # negates the result of the call.
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
        # Unary `+`, `!` and `~`, Ruby's tightest tier. Unlike `-`,
        # `+` never fuses into a literal.
        op = advance.kind
        Unary.new(op, parse_unary, l, c)
      when TokenKind::Tilde
        op = advance.kind
        Unary.new(op, parse_unary, l, c)
      when TokenKind::BangTilde
        # `!~x` in prefix position is `!(~x)`. The lexer makes `!~` one
        # token for the infix operator, so the two unary nodes are
        # rebuilt here, both at the `!~` token's position.
        advance
        Unary.new(TokenKind::Bang, Unary.new(TokenKind::Tilde, parse_unary, l, c), l, c)
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
      when TokenKind::RangeIncl, TokenKind::RangeExcl
        # A beginless range: `..10` or `...10`.
        op_tok = @current
        advance
        right = range_end_omitted? ? nil : parse_expression(token_precedence(op_tok.kind))
        RangeLiteral.new(nil, right, op_tok.kind == TokenKind::RangeExcl, l, c)
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
      when TokenKind::KwFile
        # `__FILE__` is known at parse time, so it becomes a string
        # literal.
        advance
        StringLiteral.new(@lexer.filename, l, c)
      when TokenKind::KwLine
        # `__LINE__` is known at parse time, so it becomes an integer
        # literal.
        advance
        IntLiteral.new(l.to_s, l, c)
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
        is_double = tok.lexeme.starts_with?('"')
        StringLiteral.new(decode_string_escapes(strip_quotes(tok.lexeme), is_double), l, c)
      when TokenKind::StringPart
        parse_interp_string(l, c)
      when TokenKind::Regex
        tok = advance
        RegexLiteral.new([RegexFragment.new(tok.lexeme, l, c)] of Node, tok.regex_flags, l, c)
      when TokenKind::RegexPart
        parse_regex_literal(l, c)
      when TokenKind::Symbol
        tok = advance
        SymbolLiteral.new(tok.lexeme.lstrip(':').strip('"').strip('\''), l, c)
      when TokenKind::PercentWords
        tok = advance
        ArrayLiteral.new(split_percent_literal(tok.lexeme).map { |word| StringLiteral.new(word, tok.line, tok.column).as(Node) }, l, c)
      when TokenKind::PercentSymbols
        tok = advance
        ArrayLiteral.new(split_percent_literal(tok.lexeme).map { |word| SymbolLiteral.new(word, tok.line, tok.column).as(Node) }, l, c)
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
      when TokenKind::KwYield
        parse_yield
      when TokenKind::KwSuper
        # `super` as a sub-expression: `"B-" + super()`, `x = super`.
        parse_super
      when TokenKind::GVar
        # Global variables are excluded (U011), and rejected here by
        # name rather than as a generic P002.
        raise ParseError.new(
          Diagnostic.new(
            code: "U011",
            primary: Span.new(
              line: l,
              column: c,
              length: caret_width(@current),
              label: "not supported"
            ),
            data: {"name" => @current.lexeme}
          )
        )
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

    # Whether the current `-` or `+` starts a bare call's first
    # argument rather than being binary: space before it and none
    # after (`eq -1`). `a - b`, `a-b` and `n - 1` are binary, as in
    # Ruby, whether or not `a` is a local.
    private def signed_literal_starts_bare_call? : Bool
      (at_kind?(TokenKind::Minus) || at_kind?(TokenKind::Plus)) &&
        @current.space_before? && operand_immediately_follows?
    end

    # Parses a bare identifier as a local variable or a method call.
    private def parse_identifier_or_call(l : Int32, c : Int32) : Node
      tok = advance
      name = tok.lexeme
      if at_kind?(TokenKind::LParen) && !@current.space_before?
        # `name(...)`: its own argument list. With a space before the
        # `(`, as in `eq (6/3), 2`, the parenthesized expression is the
        # first argument of a bare call instead.
        args, kwargs, blk = parse_call_args_and_block
        Call.new(nil, name, args, blk, false, l, c, kwargs: kwargs)
      elsif block_follows_no_paren?
        blk = parse_block
        Call.new(nil, name, [] of Node, blk, false, l, c)
      elsif at_kind?(TokenKind::LBracket)
        # `name [x]`: indexing if `name` is a local, otherwise a call
        # with an array argument, as in Ruby.
        known_local?(name) ? Identifier.new(name, l, c) : parse_bare_call_args(name, l, c)
      elsif signed_literal_starts_bare_call?
        # `name -x` or `name +x`; see
        # `signed_literal_starts_bare_call?`.
        parse_bare_call_args(name, l, c)
      elsif arg_follows_no_paren?
        # A bare call: `puts x`, `raise "msg"`.
        parse_bare_call_args(name, l, c)
      else
        Identifier.new(name, l, c)
      end
    end

    # Parses a bare call's comma-separated arguments and optional
    # block.
    private def parse_bare_call_args(name : String, l : Int32, c : Int32) : Call
      args = [] of Node
      kwargs = [] of {String, Node}
      parse_call_arg(args, kwargs)
      while match(TokenKind::Comma)
        skip_newlines
        parse_call_arg(args, kwargs)
      end
      blk = parse_block if block_follows_no_paren?
      Call.new(nil, name, args, blk, false, l, c, kwargs: kwargs)
    end

    private def block_follows_no_paren? : Bool
      return at_kind?(TokenKind::LBrace) if @no_do_block
      at_any?(TokenKind::KwDo, TokenKind::LBrace)
    end

    # Whether the current token starts an argument of a bare call:
    # a literal, identifier, constant, variable, prefix operator,
    # opening delimiter or keyword literal. An allowlist, so operators
    # and terminators are never read as arguments. `[` qualifies:
    # `name [` has already been decided by `known_local?`, and after
    # `raise` or `super` it can only start an array.
    private def arg_follows_no_paren? : Bool
      case current_kind
      when TokenKind::Integer, TokenKind::Float,
           TokenKind::String, TokenKind::StringPart,
           TokenKind::Regex, TokenKind::RegexPart,
           TokenKind::Symbol, TokenKind::KwSelf,
           TokenKind::KwNil, TokenKind::KwTrue, TokenKind::KwFalse,
           TokenKind::KwFile, TokenKind::KwLine,
           TokenKind::Bang, TokenKind::Tilde,
           TokenKind::LParen, TokenKind::LBracket,
           TokenKind::Identifier, TokenKind::Constant
        true
      when TokenKind::Minus
        # `-` and `+` are decided by
        # `signed_literal_starts_bare_call?`, which sees spacing. So
        # `raise -1` is not supported.
        false
      else
        false
      end
    end

    # --- Calls --------------------------------------------------------------

    # Parses one call argument into `args`, or into `kwargs` when it
    # is `name: value`. The lookahead for `:` as the second token keeps
    # a ternary's `? a : b` out.
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
      # `@no_pipe` is off inside a block literal, even one written as
      # a parameter default, and restored afterwards.
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
        skip_newlines
        break unless match(TokenKind::Comma)
        skip_newlines
      end
      expect(TokenKind::Pipe)
      params
    end

    # --- Literals -----------------------------------------------------------

    private def parse_interp_string(l : Int32, c : Int32) : Node
      parts = [] of Node
      while at_kind?(TokenKind::StringPart)
        tok = advance
        parts << StringFragment.new(decode_string_escapes(tok.lexeme, true), tok.line, tok.column)
        # Parses the interpolated expression up to InterpEnd.
        skip_newlines
        until at_kind?(TokenKind::InterpEnd) || at_kind?(TokenKind::EOF)
          parts << parse_expression(0)
          skip_terminators
        end
        expect(TokenKind::InterpEnd)
      end
      if at_kind?(TokenKind::StringEnd)
        tok = advance
        parts << StringFragment.new(decode_string_escapes(tok.lexeme, true), tok.line, tok.column) unless tok.lexeme.empty?
      end
      InterpString.new(parts, l, c)
    end

    # Parses a regex literal containing `#{...}`. Fragments keep their
    # raw text; the flags come from the final RegexEnd token.
    private def parse_regex_literal(l : Int32, c : Int32) : Node
      parts = [] of Node
      flags = ""
      while at_kind?(TokenKind::RegexPart)
        tok = advance
        parts << RegexFragment.new(tok.lexeme, tok.line, tok.column)
        skip_newlines
        until at_kind?(TokenKind::InterpEnd) || at_kind?(TokenKind::EOF)
          parts << parse_expression(0)
          skip_terminators
        end
        expect(TokenKind::InterpEnd)
      end
      if at_kind?(TokenKind::RegexEnd)
        tok = advance
        parts << RegexFragment.new(tok.lexeme, tok.line, tok.column) unless tok.lexeme.empty?
        flags = tok.regex_flags
      end
      RegexLiteral.new(parts, flags, l, c)
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
      # A `{` in expression position is always a hash literal; a
      # block's `{` is consumed where a call is parsed.
      expect(TokenKind::LBrace)
      pairs = [] of {Node, Node}
      skip_newlines
      until at_kind?(TokenKind::RBrace) || at_kind?(TokenKind::EOF)
        key = parse_hash_key
        val = parse_expression(0)
        pairs << {key, val}
        skip_newlines
        break unless match(TokenKind::Comma)
        skip_newlines
      end
      expect(TokenKind::RBrace)
      HashLiteral.new(pairs, l, c)
    end

    # Parses a hash entry's key and its separator: `key => val` with
    # any expression as key, or `key: val`, where an identifier,
    # constant or keyword touching `:` becomes a Symbol.
    private def label_follows? : Bool
      return false unless at_kind?(TokenKind::Identifier) || at_kind?(TokenKind::Constant) ||
                          @current.kind.to_s.starts_with?("Kw")
      @next.kind == TokenKind::Colon && !@next.space_before?
    end

    private def parse_hash_key : Node
      if label_follows?
        l, c = line, col
        name = @current.lexeme
        advance # the label itself
        advance # its hugging `:`
        return SymbolLiteral.new(name, l, c)
      end
      key = parse_expression(0)
      expect(TokenKind::HashRocket)
      key
    end

    # --- Definitions --------------------------------------------------------

    private def parse_def : DefNode
      l, c = line, col
      open_block("def", l, c)
      expect(TokenKind::KwDef)
      recv = nil
      name_tok = @current
      advance
      # `def obj.method` or `def self.method`.
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
      # A setter, `def name=(value)`: an identifier touching a lone
      # `=`. `def foo ==(x)` lexes as `EqEq`, so doesn't match.
      if name_tok.kind == TokenKind::Identifier && at_kind?(TokenKind::Eq) && !@current.space_before?
        advance
        name_tok = Token.new(TokenKind::Identifier, "#{name_tok.lexeme}=", name_tok.line, name_tok.column)
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
      body = parse_body_until_any(TokenKind::KwRescue, TokenKind::KwElse, TokenKind::KwEnsure, TokenKind::KwEnd)
      rescue_clauses, else_body, ensure_body = parse_rescue_else_ensure
      # A method body is an implicit `begin`: with a `rescue` or
      # `ensure`, the body is wrapped in a BeginNode.
      unless rescue_clauses.empty? && ensure_body.nil?
        begin_node = BeginNode.new(body, rescue_clauses, else_body, ensure_body, l, c)
        body = Body.new([begin_node.as(Node)], l, c)
      end
      close_block
      pop_local_scope
      DefNode.new(name_tok.lexeme, recv, params, body, l, c)
    end

    private def parse_param_list : Array(Param)
      params = [] of Param
      until at_kind?(TokenKind::RParen) || at_kind?(TokenKind::EOF)
        params << parse_param
        skip_newlines
        break unless match(TokenKind::Comma)
        skip_newlines
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
      # A keyword parameter: `name:` or `name: default`.
      if at_kind?(TokenKind::Colon)
        advance
        # A non-empty default needs `@no_pipe`, as below, for
        # `|k: 9|`.
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
      # An optional parameter: `name = value`.
      if at_kind?(TokenKind::Eq)
        advance
        # `@no_pipe` matters only in a block's `|...|`, but is set for
        # def parameters too, so one path serves both.
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
      # An optional `do` after the condition.
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
      # `loop do ... end` or `loop { ... }`. Only the `do` form needs
      # an `end`, so only it is tracked.
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
        skip_newlines
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
      # A `for` variable joins the current scope and outlives the
      # loop, as in Ruby.
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
          skip_newlines
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

    # True when `return`, `break` or `next` is followed by its optional
    # value. A trailing `if` or `unless` is always the modifier, never
    # the start of the value, so `next unless x` skips on `x` rather
    # than reading `unless x ... end` as the value to return.
    private def jump_value_follows? : Bool
      !at_any?(TokenKind::Newline, TokenKind::Semi, TokenKind::EOF, TokenKind::KwIf, TokenKind::KwUnless)
    end

    private def parse_return : Node
      l, c = line, col
      expect(TokenKind::KwReturn)
      value = jump_value_follows? ? parse_expression(0) : nil
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
      value = jump_value_follows? ? parse_expression(0) : nil
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
        skip_newlines
        until at_kind?(TokenKind::RParen) || at_kind?(TokenKind::EOF)
          args << parse_expression(0)
          skip_newlines
          break unless match(TokenKind::Comma)
          skip_newlines
        end
        expect(TokenKind::RParen)
      elsif arg_follows_no_paren?
        # Without the check, `x = yield + 1` would read `+ 1` as an
        # argument.
        args << parse_expression(0)
        while match(TokenKind::Comma)
          skip_newlines
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
        skip_newlines
        args = [] of Node
        until at_kind?(TokenKind::RParen) || at_kind?(TokenKind::EOF)
          args << parse_expression(0)
          skip_newlines
          break unless match(TokenKind::Comma)
          skip_newlines
        end
        expect(TokenKind::RParen)
        SuperNode.new(args, false, l, c)
      elsif arg_follows_no_paren?
        # `arg_follows_no_paren?` rejects `+` and `-`, so `super + 4`
        # adds to super's result instead of passing `+4`.
        args = [parse_expression(0)] of Node
        while match(TokenKind::Comma)
          skip_newlines
          args << parse_expression(0)
        end
        SuperNode.new(args, false, l, c)
      else
        # Bare `super` forwards the method's current parameter values
        # (zsuper), rather than calling with no arguments.
        SuperNode.new([] of Node, true, l, c)
      end
    end

    # Parses `raise`, `raise "msg"` or `raise("msg")` into a Call to
    # the builtin `raise`.
    private def parse_raise(l : Int32, c : Int32) : Node
      advance # consume 'raise'
      args = [] of Node
      if at_kind?(TokenKind::LParen)
        args, _kwargs, _blk = parse_call_args_and_block
      elsif arg_follows_no_paren?
        args << parse_expression(0)
        while match(TokenKind::Comma)
          skip_newlines
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
      body = parse_body_until_any(TokenKind::KwRescue, TokenKind::KwElse, TokenKind::KwEnsure, TokenKind::KwEnd)
      rescue_clauses, else_body, ensure_body = parse_rescue_else_ensure
      close_block
      BeginNode.new(body, rescue_clauses, else_body, ensure_body, l, c)
    end

    # Parses the rescue, else and ensure clauses after a `begin` body
    # or a method body (an implicit `begin`). Returns empty results
    # when there are none. The caller consumes the closing `end`.
    private def parse_rescue_else_ensure : {Array(RescueClause), Body?, Body?}
      rescue_clauses = [] of RescueClause
      while at_kind?(TokenKind::KwRescue)
        rescue_clauses << parse_rescue_clause
      end
      else_body = parse_begin_else(rescue_clauses)
      ensure_body = nil
      if match(TokenKind::KwEnsure)
        skip_terminators
        ensure_body = parse_body_until(TokenKind::KwEnd)
      end
      {rescue_clauses, else_body, ensure_body}
    end

    # Parses one `rescue` clause: optional classes (`rescue A, B`,
    # tried left to right), optional `=> var` binding, then its body.
    private def parse_rescue_clause : RescueClause
      expect(TokenKind::KwRescue)
      classes = [] of Node
      rescue_var = nil
      if at_kind?(TokenKind::Constant)
        # Parsed as an expression so `rescue Foo::Bar` works.
        classes << parse_expression(0)
        while match(TokenKind::Comma)
          skip_newlines
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
        # `rescue e` is accepted as `rescue => e`. Ruby would treat
        # `e` as the class to match.
        rescue_var = @current.lexeme
        advance
      end
      skip_terminators
      # A rescue variable joins the current scope and outlives the
      # `begin`, as in Ruby.
      rescue_var.try { |v| register_local(v) }
      rescue_body = parse_body_until_any(TokenKind::KwRescue, TokenKind::KwElse, TokenKind::KwEnsure, TokenKind::KwEnd)
      RescueClause.new(classes, rescue_var, rescue_body)
    end

    # Parses `begin`'s optional `else` clause.
    private def parse_begin_else(rescue_clauses : Array(RescueClause)) : Body?
      return unless at_kind?(TokenKind::KwElse)
      # As in Ruby, `else` needs a `rescue` before it.
      raise else_without_rescue_error if rescue_clauses.empty?
      advance
      skip_terminators
      else_body = parse_body_until_any(TokenKind::KwElse, TokenKind::KwEnsure, TokenKind::KwEnd)
      # As in Ruby, a `begin` has at most one `else`.
      raise duplicate_else_error if at_kind?(TokenKind::KwElse)
      else_body
    end

    private def else_without_rescue_error : ParseError
      span = Span.new(
        line: @current.line,
        column: @current.column,
        length: caret_width(@current),
        label: "else without rescue is useless"
      )
      ParseError.new(Diagnostic.new(code: "P004", primary: span))
    end

    private def duplicate_else_error : ParseError
      span = Span.new(
        line: @current.line,
        column: @current.column,
        length: caret_width(@current),
        label: "a begin block can have only one else clause"
      )
      ParseError.new(Diagnostic.new(code: "P005", primary: span))
    end

    private def parse_require : RequireNode
      l, c = line, col
      expect(TokenKind::KwRequire)
      path = parse_expression(0)
      RequireNode.new(path, l, c)
    end

    # Desugars `attr_reader`, `attr_writer` or `attr_accessor` with
    # literal Symbol names (`attr_accessor :x, :y`, parentheses
    # optional) into a Body of the DefNodes the equivalent
    # hand-written methods would produce.
    private def parse_attr(kind : TokenKind) : Node
      l, c = line, col
      advance # consume attr_reader / attr_writer / attr_accessor itself
      paren = match(TokenKind::LParen)
      names = [] of String
      loop do
        tok = expect(TokenKind::Symbol)
        names << tok.lexeme.lstrip(':').strip('"').strip('\'')
        break unless match(TokenKind::Comma)
        skip_newlines
      end
      expect(TokenKind::RParen) if paren
      defs = [] of Node
      names.each do |name|
        ivar_name = "@#{name}"
        if kind == TokenKind::KwAttrReader || kind == TokenKind::KwAttrAccessor
          reader_body = Body.new([IVar.new(ivar_name, l, c)] of Node, l, c)
          defs << DefNode.new(name, nil, [] of Param, reader_body, l, c)
        end
        if kind == TokenKind::KwAttrWriter || kind == TokenKind::KwAttrAccessor
          value_param = Param.new("value", nil, false, false, false, l, c)
          setter_body = Body.new([
            Assign.new(IVar.new(ivar_name, l, c), Identifier.new("value", l, c), l, c),
          ] of Node, l, c)
          defs << DefNode.new("#{name}=", nil, [value_param], setter_body, l, c)
        end
      end
      Body.new(defs, l, c)
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
        append_statement(stmts, parse_statement)
        skip_terminators
      end
      Body.new(stmts, l, c)
    end

    private def parse_body_until_any(*kinds : TokenKind) : Body
      l, c = line, col
      stmts = [] of Node
      skip_terminators
      until at_any?(*kinds) || at_kind?(TokenKind::EOF)
        append_statement(stmts, parse_statement)
        skip_terminators
      end
      Body.new(stmts, l, c)
    end

    # Appends `stmt`, splicing in a Body's statements (as `parse_attr`
    # returns) rather than nesting it. `RiskWalker#walk_class` only
    # registers DefNodes that are direct statements of a class body.
    private def append_statement(stmts : Array(Node), stmt : Node) : Nil
      if stmt.is_a?(Body)
        stmts.concat(stmt.stmts)
      else
        stmts << stmt
      end
    end

    # --- Utilities ----------------------------------------------------------

    private def strip_quotes(s : String) : String
      return s[1..-2] if s.size >= 2 && (s.starts_with?('"') || s.starts_with?('\''))
      s
    end

    # Splits a `%w` or `%i` literal's raw body into words at runs of
    # whitespace. `\` before whitespace keeps it in the word, and `\\`
    # is one backslash; no other escapes apply.
    private def split_percent_literal(raw : String) : Array(String)
      words = [] of String
      current = String::Builder.new
      has_content = false
      i = 0
      n = raw.size
      while i < n
        ch = raw[i]
        if ch == '\\' && i + 1 < n
          current << raw[i + 1]
          has_content = true
          i += 2
          next
        end
        if ch.ascii_whitespace?
          if has_content
            words << current.to_s
            current = String::Builder.new
            has_content = false
          end
          i += 1
          next
        end
        current << ch
        has_content = true
        i += 1
      end
      words << current.to_s if has_content
      words
    end

    # Decodes backslash escapes in a string literal's raw text. With
    # `is_double`, Ruby's double-quoted escapes apply; otherwise only
    # `\\` and `\'` do, and every other backslash stays literal.
    # Interpolated-string fragments are always double-quoted.
    # ameba:disable Metrics/CyclomaticComplexity - one `when` per escape letter, each a flat one-line case; not tangled branching
    private def decode_string_escapes(raw : String, is_double : Bool) : String
      return decode_single_quoted_escapes(raw) unless is_double

      String.build do |io|
        i = 0
        n = raw.size
        while i < n
          ch = raw[i]
          if ch == '\\' && i + 1 < n
            nxt = raw[i + 1]
            case nxt
            when 'n'                  then io << '\n'; i += 2
            when 't'                  then io << '\t'; i += 2
            when 'r'                  then io << '\r'; i += 2
            when '0'                  then io << '\0'; i += 2
            when 'a'                  then io << '\a'; i += 2
            when 'b'                  then io << '\b'; i += 2
            when 'e'                  then io << '\e'; i += 2
            when 'f'                  then io << '\f'; i += 2
            when 'v'                  then io << '\v'; i += 2
            when 's'                  then io << ' '; i += 2
            when '\\', '"', '\'', '#' then io << nxt; i += 2
            when 'x'
              j = i + 2
              j += 1 if j < n && hex_digit?(raw[j])
              j += 1 if j < n && hex_digit?(raw[j]) && j == i + 3
              if j == i + 2
                io << nxt
                i += 2
              else
                io << raw[(i + 2)...j].to_i(16).chr
                i = j
              end
            when 'u'
              if i + 2 < n && raw[i + 2] == '{'
                close = raw.index('}', i + 3)
                if close
                  hex = raw[(i + 3)...close]
                  io << hex.to_i(16).chr unless hex.empty?
                  i = close + 1
                else
                  io << nxt
                  i += 2
                end
              elsif i + 6 <= n && (i + 2...i + 6).all? { |k| hex_digit?(raw[k]) }
                io << raw[(i + 2)...(i + 6)].to_i(16).chr
                i += 6
              else
                io << nxt
                i += 2
              end
            else
              # An unknown escape drops the backslash, as in Ruby:
              # `"\d" == "d"`.
              io << nxt
              i += 2
            end
          else
            io << ch
            i += 1
          end
        end
      end
    end

    private def hex_digit?(c : Char) : Bool
      c.ascii_number? || ('a'..'f').includes?(c.downcase)
    end

    # Decodes a single-quoted string's only escapes, `\\` and `\'`,
    # in one left-to-right pass.
    private def decode_single_quoted_escapes(raw : String) : String
      String.build do |io|
        i = 0
        n = raw.size
        while i < n
          ch = raw[i]
          if ch == '\\' && i + 1 < n && (raw[i + 1] == '\\' || raw[i + 1] == '\'')
            io << raw[i + 1]
            i += 2
          else
            io << ch
            i += 1
          end
        end
      end
    end
  end
end
