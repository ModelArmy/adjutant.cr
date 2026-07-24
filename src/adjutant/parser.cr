require "./token"
require "./lexer"
require "./ast"

module Adjutant
  class ParseError < Exception
    getter line : Int32
    getter column : Int32

    def initialize(message : String, @line, @column)
      super("#{message} (line #{line}, col #{column})")
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

    # Only a bare `Identifier` LHS introduces a new local name — `@ivar
    # = x`, `arr[0] = x`, `obj.attr = x` etc. are all valid assignment
    # targets too but none of them make a NEW bare name resolvable as a
    # local afterward.
    private def register_local_if_identifier(lhs : Node) : Nil
      register_local(lhs.name) if lhs.is_a?(Identifier)
    end

    def initialize(source : IO, filename : String = "<input>")
      @lexer = Lexer.new(source, filename)
      @current = @lexer.next_token
      @next = @lexer.next_token
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

    private def expect(kind : TokenKind) : Token
      raise ParseError.new("expected #{kind}, got #{@current.kind} (#{@current.lexeme.inspect})", @current.line, @current.column) unless at_kind?(kind)
      advance
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
      when TokenKind::KwBegin   then parse_begin
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

    # An expression that may be followed by a modifier (if/unless/while/until).
    # Modifiers are checked AFTER assignment so `x -= 1 while x > 0` works.
    private def parse_expr_statement : Node
      expr = parse_expression(0)
      result = maybe_assignment(expr)
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
          args, blk = parse_call_args_and_block
          node = Call.new(node, method_tok.lexeme, args, blk, safe, l, c)
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
        raise ParseError.new("unexpected token #{current_kind} (#{@current.lexeme.inspect})", l, c)
      end
    end

    # Bare identifier — may be a local variable, a bare method call, or
    # a keyword-like call (puts, require handled in parse_statement).
    private def parse_identifier_or_call(l : Int32, c : Int32) : Node
      tok = advance
      name = tok.lexeme
      if at_kind?(TokenKind::LParen)
        args, blk = parse_call_args_and_block
        Call.new(nil, name, args, blk, false, l, c)
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
        if known_local?(name)
          Identifier.new(name, l, c) # falls through to parse_postfix's own LBracket handling as indexing
        else
          args = [parse_expression(0)] of Node
          while match(TokenKind::Comma)
            args << parse_expression(0)
          end
          blk = parse_block if block_follows_no_paren?
          Call.new(nil, name, args, blk, false, l, c)
        end
      elsif arg_follows_no_paren?
        # bare call: `puts x`, `raise "msg"`, etc.
        args = [parse_expression(0)] of Node
        while match(TokenKind::Comma)
          args << parse_expression(0)
        end
        blk = parse_block if block_follows_no_paren?
        Call.new(nil, name, args, blk, false, l, c)
      else
        Identifier.new(name, l, c)
      end
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
        false # REVISIT, can minus ever be valid token after method call name?
      else
        false
      end
    end

    # --- Calls --------------------------------------------------------------

    private def parse_call_args_and_block : {Array(Node), BlockNode?}
      args = [] of Node
      blk = nil
      if at_kind?(TokenKind::LParen)
        advance
        skip_newlines
        unless at_kind?(TokenKind::RParen)
          args << parse_expression(0)
          while match(TokenKind::Comma)
            skip_newlines
            break if at_kind?(TokenKind::RParen)
            args << parse_expression(0)
          end
        end
        skip_newlines
        expect(TokenKind::RParen)
      end
      blk = parse_block if block_follows_no_paren?
      {args, blk}
    end

    private def parse_block : BlockNode
      l, c = line, col
      push_local_scope(inherit: true)
      if at_kind?(TokenKind::KwDo)
        advance
        params = parse_block_params
        params.each { |param| register_local(param.name) }
        skip_newlines
        body = parse_body_until(TokenKind::KwEnd)
        expect(TokenKind::KwEnd)
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
      expect(TokenKind::KwEnd)
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
        default = at_any?(TokenKind::Comma, TokenKind::RParen, TokenKind::Pipe) ? nil : parse_expression(0)
        return Param.new(name, default, false, false, true, l, c)
      end
      # default parameter: name = value
      if at_kind?(TokenKind::Eq)
        advance
        default = parse_expression(0)
        return Param.new(name, default, false, false, false, l, c)
      end
      Param.new(name, nil, false, false, false, l, c)
    end

    private def parse_class : ClassNode
      l, c = line, col
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
      expect(TokenKind::KwEnd)
      ClassNode.new(name, superclass, body, l, c)
    end

    private def parse_module : ModuleNode
      l, c = line, col
      expect(TokenKind::KwModule)
      name = @current.lexeme
      advance
      skip_terminators
      push_local_scope(inherit: false)
      body = parse_body_until(TokenKind::KwEnd)
      pop_local_scope
      expect(TokenKind::KwEnd)
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
               expect(TokenKind::KwDo)
               b = parse_body_until(TokenKind::KwEnd)
               expect(TokenKind::KwEnd)
               b
             end
      pop_local_scope
      Lambda.new(params, body, l, c)
    end

    # --- Control flow -------------------------------------------------------

    private def parse_if : IfNode
      l, c = line, col
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
      expect(TokenKind::KwEnd)
      IfNode.new(cond, then_branch, elsifs, else_branch, l, c)
    end

    private def parse_unless : UnlessNode
      l, c = line, col
      expect(TokenKind::KwUnless)
      cond = parse_expression(0)
      skip_terminators
      then_branch = parse_body_until_any(TokenKind::KwElse, TokenKind::KwEnd, TokenKind::KwEnd)
      else_branch = nil
      if match(TokenKind::KwElse)
        skip_terminators
        else_branch = parse_body_until(TokenKind::KwEnd)
      end
      expect(TokenKind::KwEnd)
      UnlessNode.new(cond, then_branch, else_branch, l, c)
    end

    private def parse_while(until_loop : Bool) : WhileNode
      l, c = line, col
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
      expect(TokenKind::KwEnd)
      WhileNode.new(cond, body, until_loop, l, c)
    end

    private def parse_loop : LoopNode
      l, c = line, col
      expect(TokenKind::KwLoop)
      skip_terminators
      # loop do ... end or loop { ... }
      if at_kind?(TokenKind::KwDo)
        advance
        body = parse_body_until(TokenKind::KwEnd)
        expect(TokenKind::KwEnd)
      else
        expect(TokenKind::LBrace)
        body = parse_body_until(TokenKind::RBrace)
        expect(TokenKind::RBrace)
      end
      LoopNode.new(body, l, c)
    end

    private def parse_for : ForNode
      l, c = line, col
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
      expect(TokenKind::KwEnd)
      ForNode.new(vars, iter, body, l, c)
    end

    private def parse_case : CaseNode
      l, c = line, col
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
      expect(TokenKind::KwEnd)
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
        args, _blk = parse_call_args_and_block
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
      expect(TokenKind::KwBegin)
      skip_terminators
      body = parse_body_until_any(TokenKind::KwRescue, TokenKind::KwEnsure, TokenKind::KwEnd)
      rescue_class = nil
      rescue_var = nil
      rescue_body = nil
      ensure_body = nil
      if match(TokenKind::KwRescue)
        if at_kind?(TokenKind::Constant)
          # Reuses the normal expression parser so `rescue Foo::Bar`
          # gets full constant-path support for free.
          rescue_class = parse_expression(0)
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
        rescue_body = parse_body_until_any(TokenKind::KwEnsure, TokenKind::KwEnd, TokenKind::KwEnd)
      end
      if match(TokenKind::KwEnsure)
        skip_terminators
        ensure_body = parse_body_until(TokenKind::KwEnd)
      end
      expect(TokenKind::KwEnd)
      BeginNode.new(body, rescue_class, rescue_var, rescue_body, ensure_body, l, c)
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
