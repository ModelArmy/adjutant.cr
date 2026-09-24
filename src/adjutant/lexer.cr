require "./token"

module Adjutant
  # Converts source text into Tokens. Call `next_token` until EOF, or
  # `tokenize` to collect them all.
  class Lexer
    # The literal an open `#{...}` belongs to, so scanning resumes
    # after its `}` looking for the right terminator: `"` for a
    # string, `/` and flags for a regex.
    enum InterpKind
      Str
      Regex
      Heredoc
    end

    getter filename : String

    # The full source text, kept for diagnostic rendering.
    getter source : String

    # Reads `io` into memory, since scanning needs random access.
    def initialize(io : IO, filename : String = "<input>")
      @source = io.gets_to_end
      @filename = filename
      @pos = 0
      @line = 1
      @column = 1
      @in_interp = false
      @interp_brace_depth = 0
      @interp_kind = InterpKind::Str
      @space_before = false
      # The last non-space, non-comment token kind, which decides
      # whether a bare `/` or `<<` starts a literal. Nil at the start
      # of the source.
      @prev_kind = nil.as(TokenKind?)
      # Heredocs are tokenized whole when their opener is scanned, so
      # their tokens sit at the opener's position. `@pending_tokens`
      # holds the rest of that token sequence. The body sits on the
      # following lines, so when the newline at `@pending_heredoc_skip_at`
      # is reached, scanning jumps past the body to
      # `@pending_heredoc_skip_to_pos`. One heredoc per line is
      # supported, so one set of these suffices.
      @pending_tokens = [] of Token
      @pending_heredoc_skip_at = nil.as(Int32?)
      @pending_heredoc_skip_to_pos = 0
      @pending_heredoc_skip_to_line = 0
    end

    # Convenience constructor for string literals and tests.
    def initialize(source : String, filename : String = "<input>")
      initialize(IO::Memory.new(source), filename)
    end

    # Tokenize the entire source and return all tokens including EOF.
    def tokenize : Array(Token)
      tokens = [] of Token
      loop do
        tok = next_token
        tokens << tok
        break if tok.kind == TokenKind::EOF
      end
      tokens
    end

    def next_token : Token
      tok = next_token_inner
      @prev_kind = tok.kind
      tok
    end

    private def next_token_inner : Token
      return @pending_tokens.shift unless @pending_tokens.empty?

      if @in_interp && @interp_brace_depth == 0
        return continue_interp
      end

      # Whether whitespace or a comment precedes the token being
      # scanned; `make_token` attaches it to every token.
      @space_before = skip_whitespace_and_comments

      line = @line
      col = @column
      start = @pos

      return make_token(TokenKind::EOF, "", line, col) if at_end?

      c = advance
      if c == '\n'
        # A heredoc's body starts after this newline and has already
        # been tokenized: skip it.
        if (skip_at = @pending_heredoc_skip_at) && skip_at == start
          @pos = @pending_heredoc_skip_to_pos
          @line = @pending_heredoc_skip_to_line
          @column = 1
          @pending_heredoc_skip_at = nil
        end
        return make_token(TokenKind::Newline, "\n", line, col)
      end

      scan(c, start, line, col)
    end

    # -----------------------------------------------------------------------

    private def at_end? : Bool
      @pos >= @source.size
    end

    private def current_char : Char
      at_end? ? '\0' : @source[@pos]
    end

    private def peek_next : Char
      @pos + 1 < @source.size ? @source[@pos + 1] : '\0'
    end

    # The character `offset` places ahead, or '\0' past the end.
    private def peek_at(offset : Int32) : Char
      @pos + offset < @source.size ? @source[@pos + offset] : '\0'
    end

    private def advance : Char
      c = @source[@pos]
      @pos += 1
      if c == '\n'
        @line += 1
        @column = 1
      else
        @column += 1
      end
      c
    end

    private def match(expected : Char) : Bool
      return false if at_end? || current_char != expected
      advance
      true
    end

    # Skips spaces, tabs and comments. Returns whether anything was
    # skipped, which becomes the next token's `space_before`.
    private def skip_whitespace_and_comments : Bool
      consumed = false
      loop do
        case current_char
        when ' ', '\t', '\r'
          advance
          consumed = true
        when '#'
          while !at_end? && current_char != '\n'
            advance
          end
          consumed = true
        else
          break
        end
      end
      consumed
    end

    private def make_token(kind : TokenKind, lexeme : String, line : Int32, col : Int32) : Token
      Token.new(kind, lexeme, line, col, @space_before)
    end

    private def lexeme_from(start : Int32) : String
      @source[start, @pos - start]
    end

    # Resumes a string or regex body after an interpolation's `}`.
    private def continue_interp : Token
      case @interp_kind
      when InterpKind::Regex
        continue_interp_regex
      when InterpKind::Heredoc
        continue_interp_heredoc
      else
        continue_interp_string
      end
    end

    private def continue_interp_string : Token
      @in_interp = false
      # A resumed literal is never preceded by space.
      @space_before = false
      line = @line
      col = @column
      start = @pos

      while !at_end?
        c = current_char
        if c == '\\'
          advance
          advance unless at_end?
          next
        end
        if c == '"'
          content = @source[start, @pos - start]
          advance
          return make_token(TokenKind::StringEnd, content, line, col)
        end
        if c == '#' && peek_next == '{'
          content = @source[start, @pos - start]
          advance # #
          advance # {
          @in_interp = true
          @interp_brace_depth = 1
          return make_token(TokenKind::StringPart, content, line, col)
        end
        advance
      end
      make_token(TokenKind::Error, "unterminated string", line, col)
    end

    # Resumes a heredoc body after an interpolation's `}`. The body is
    # this lexer's whole source, so only end of source terminates it.
    private def continue_interp_heredoc : Token
      @in_interp = false
      @space_before = false
      line = @line
      col = @column
      start = @pos

      while !at_end?
        c = current_char
        if c == '\\'
          advance
          advance unless at_end?
          next
        end
        if c == '#' && peek_next == '{'
          content = @source[start, @pos - start]
          advance # #
          advance # {
          @in_interp = true
          @interp_brace_depth = 1
          return make_token(TokenKind::StringPart, content, line, col)
        end
        advance
      end
      content = @source[start, @pos - start]
      make_token(TokenKind::StringEnd, content, line, col)
    end

    private def continue_interp_regex : Token
      @in_interp = false
      @space_before = false
      line = @line
      col = @column
      start = @pos

      while !at_end?
        c = current_char
        if c == '\\'
          advance
          advance unless at_end?
          next
        end
        if c == '/'
          content = @source[start, @pos - start]
          advance
          flags = scan_regex_flags
          return Token.new(TokenKind::RegexEnd, content, line, col, false, flags)
        end
        if c == '#' && peek_next == '{'
          content = @source[start, @pos - start]
          advance # #
          advance # {
          @in_interp = true
          @interp_brace_depth = 1
          return make_token(TokenKind::RegexPart, content, line, col)
        end
        advance
      end
      make_token(TokenKind::Error, "unterminated regex", line, col)
    end

    # Scans one token, starting from its already-consumed first
    # character `c`.
    # ameba:disable Metrics/CyclomaticComplexity
    private def scan(c : Char, start : Int32, line : Int32, col : Int32) : Token
      case c
      when .ascii_letter?, '_'
        scan_identifier(start, line, col)
      when '@'
        scan_at_var(start, line, col)
      when '$'
        scan_global(start, line, col)
      when '0'..'9'
        scan_number(start, line, col)
      when '"', '\''
        scan_string(c, start, line, col)
      when ':'
        scan_colon(start, line, col)
      when '.'
        scan_dot(start, line, col)
      when '='
        scan_eq(start, line, col)
      when '!'
        if match('=')
          make_token(TokenKind::NEq, "!=", line, col)
        elsif match('~')
          # `!~` is one token so it gets its own precedence and
          # `x.!~(y)` parses as a method call.
          make_token(TokenKind::BangTilde, "!~", line, col)
        else
          make_token(TokenKind::Bang, "!", line, col)
        end
      when '<'
        if heredoc_starts_here?
          scan_heredoc_opener(start, line, col)
        else
          scan_lt(start, line, col)
        end
      when '>'
        scan_gt(start, line, col)
      when '&'
        scan_amp(start, line, col)
      when '|'
        if match('|')
          match('=') ? make_token(TokenKind::OrAssign, "||=", line, col) : make_token(TokenKind::OrOr, "||", line, col)
        else
          make_token(TokenKind::Pipe, "|", line, col)
        end
      when '+'
        match('=') ? make_token(TokenKind::PlusEq, "+=", line, col) : make_token(TokenKind::Plus, "+", line, col)
      when '-'
        if match('>')
          make_token(TokenKind::Arrow, "->", line, col)
        elsif match('=')
          make_token(TokenKind::MinusEq, "-=", line, col)
        else
          make_token(TokenKind::Minus, "-", line, col)
        end
      when '*'
        match('=') ? make_token(TokenKind::StarEq, "*=", line, col) : make_token(TokenKind::Star, "*", line, col)
      when '/'
        if regex_starts_here?
          scan_regex(start, line, col)
        else
          match('=') ? make_token(TokenKind::SlashEq, "/=", line, col) : make_token(TokenKind::Slash, "/", line, col)
        end
      when '%'
        if percent_literal_starts_here?
          scan_percent_literal(start, line, col)
        else
          match('=') ? make_token(TokenKind::PercentEq, "%=", line, col) : make_token(TokenKind::Percent, "%", line, col)
        end
      when '^' then make_token(TokenKind::Caret, "^", line, col)
      when '~' then make_token(TokenKind::Tilde, "~", line, col)
      when '?' then make_token(TokenKind::Question, "?", line, col)
      when '(' then make_token(TokenKind::LParen, "(", line, col)
      when ')' then make_token(TokenKind::RParen, ")", line, col)
      when '[' then make_token(TokenKind::LBracket, "[", line, col)
      when ']' then make_token(TokenKind::RBracket, "]", line, col)
      when '{'
        @interp_brace_depth += 1 if @in_interp
        make_token(TokenKind::LBrace, "{", line, col)
      when '}'
        if @in_interp
          @interp_brace_depth -= 1
          return make_token(TokenKind::InterpEnd, "}", line, col) if @interp_brace_depth == 0
        end
        make_token(TokenKind::RBrace, "}", line, col)
      when ',' then make_token(TokenKind::Comma, ",", line, col)
      when ';' then make_token(TokenKind::Semi, ";", line, col)
      else
        make_token(TokenKind::Error, c.to_s, line, col)
      end
    end

    private def ident_continue?(c : Char) : Bool
      c.ascii_alphanumeric? || c == '_'
    end

    private def scan_identifier(start : Int32, line : Int32, col : Int32) : Token
      while !at_end? && ident_continue?(current_char)
        advance
      end
      if current_char == '?' || (current_char == '!' && peek_next != '=')
        advance
      end
      word = lexeme_from(start)
      kind = KEYWORDS[word]? || (word[0].ascii_uppercase? ? TokenKind::Constant : TokenKind::Identifier)
      make_token(kind, word, line, col)
    end

    private def scan_at_var(start : Int32, line : Int32, col : Int32) : Token
      if current_char == '@'
        advance
        while !at_end? && ident_continue?(current_char)
          advance
        end
        make_token(TokenKind::CVar, lexeme_from(start), line, col)
      else
        while !at_end? && ident_continue?(current_char)
          advance
        end
        make_token(TokenKind::IVar, lexeme_from(start), line, col)
      end
    end

    private def scan_global(start : Int32, line : Int32, col : Int32) : Token
      while !at_end? && ident_continue?(current_char)
        advance
      end
      make_token(TokenKind::GVar, lexeme_from(start), line, col)
    end

    # Consumes the rest of a digit run whose first digit the caller
    # has already consumed, allowing a single `_` between digits.
    private def scan_digit_run : Nil
      while !at_end? && current_char.ascii_number?
        advance
      end
      while current_char == '_' && peek_next.ascii_number?
        advance # consume '_'
        while !at_end? && current_char.ascii_number?
          advance
        end
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def scan_number(start : Int32, line : Int32, col : Int32) : Token
      if @source[start] == '0' && (current_char == 'x' || current_char == 'X')
        advance
        while !at_end? && (current_char.ascii_number? || ('a'..'f').includes?(current_char.downcase))
          advance
        end
        return make_token(TokenKind::Integer, lexeme_from(start), line, col)
      end

      scan_digit_run

      is_float = false

      if current_char == '.' && peek_next.ascii_number?
        advance
        scan_digit_run
        is_float = true
      end

      # An exponent makes the literal a Float with or without a
      # decimal point: `1e20`, as in Ruby.
      if current_char == 'e' || current_char == 'E'
        offset = 1
        offset += 1 if peek_at(offset) == '+' || peek_at(offset) == '-'
        if peek_at(offset).ascii_number?
          advance # consume e/E
          advance if current_char == '+' || current_char == '-'
          scan_digit_run
          is_float = true
        end
      end

      make_token(is_float ? TokenKind::Float : TokenKind::Integer, lexeme_from(start), line, col)
    end

    private def scan_string(quote : Char, start : Int32, line : Int32, col : Int32) : Token
      is_double = quote == '"'

      while !at_end?
        c = current_char
        if c == '\\'
          advance
          advance unless at_end?
          next
        end
        if is_double && c == '#' && peek_next == '{'
          content = @source[start + 1, @pos - start - 1]
          advance # #
          advance # {
          @in_interp = true
          @interp_brace_depth = 1
          @interp_kind = InterpKind::Str
          return make_token(TokenKind::StringPart, content, line, col)
        end
        if c == quote
          advance
          break
        end
        advance
      end

      make_token(TokenKind::String, lexeme_from(start), line, col)
    end

    # Consumes the flag letters `i`, `m` and `x` after a regex's
    # closing `/`, stopping at any other character. Ruby would reject
    # an unknown flag; here it becomes the next token.
    private def scan_regex_flags : String
      fstart = @pos
      while !at_end? && "imx".includes?(current_char)
        advance
      end
      @source[fstart, @pos - fstart]
    end

    # Scans a regex literal after its opening `/`. `#{...}` interpolates
    # as in a double-quoted string. Escapes are not decoded: the
    # pattern text goes to the regex engine as written, and `\/`
    # matches a literal `/` there.
    private def scan_regex(start : Int32, line : Int32, col : Int32) : Token
      body_start = @pos
      while !at_end?
        c = current_char
        if c == '\\'
          advance
          advance unless at_end?
          next
        end
        if c == '/'
          content = @source[body_start, @pos - body_start]
          advance
          flags = scan_regex_flags
          return Token.new(TokenKind::Regex, content, line, col, @space_before, flags)
        end
        if c == '#' && peek_next == '{'
          content = @source[body_start, @pos - body_start]
          advance # #
          advance # {
          @in_interp = true
          @interp_brace_depth = 1
          @interp_kind = InterpKind::Regex
          return make_token(TokenKind::RegexPart, content, line, col)
        end
        advance
      end
      make_token(TokenKind::Error, "unterminated regex", line, col)
    end

    # Whether a bare `/` starts a regex rather than dividing. Ruby
    # decides from parser state; this approximates it from the
    # previous token:
    #
    #   1. After a token that can end an expression (a literal, a
    #      closing bracket, `end`), it divides: `x / y`.
    #   2. After an identifier, it starts a regex only with space
    #      before and none after, as in Ruby: `grep /foo/`.
    #   3. Anywhere else it starts a regex: `foo(/abc/)`.
    #
    # A regex also needs a closing `/` on the same line.
    private def regex_starts_here? : Bool
      prev = @prev_kind
      wants_regex =
        if prev.nil?
          true
        elsif prev == TokenKind::Identifier
          space_after = current_char == ' ' || current_char == '\t'
          @space_before && !space_after
        else
          !EXPR_END_KINDS.includes?(prev)
        end
      wants_regex && regex_closable_ahead?
    end

    # Whether an unescaped `/` follows on this line, without consuming
    # anything. A regex literal can't span lines, so without one this
    # `/` is an operator: a lone `/`, or `def /(o)`.
    private def regex_closable_ahead? : Bool
      i = @pos
      while i < @source.size
        c = @source[i]
        break if c == '\n'
        if c == '\\'
          i += 2
          next
        end
        return true if c == '/'
        i += 1
      end
      false
    end

    # Token kinds that can end an expression, after which `/` divides.
    # Identifiers are decided separately by `regex_starts_here?`.
    EXPR_END_KINDS = [
      TokenKind::Constant, TokenKind::IVar, TokenKind::CVar, TokenKind::GVar,
      TokenKind::Integer, TokenKind::Float, TokenKind::String,
      TokenKind::StringEnd, TokenKind::Regex, TokenKind::RegexEnd,
      TokenKind::Symbol,
      TokenKind::RParen, TokenKind::RBracket, TokenKind::RBrace,
      TokenKind::KwEnd, TokenKind::KwSelf, TokenKind::KwTrue,
      TokenKind::KwFalse, TokenKind::KwNil,
      TokenKind::KwFile, TokenKind::KwLine, TokenKind::KwMethodName,
      TokenKind::KwCalleeName,
    ] of TokenKind

    # ameba:disable Metrics/CyclomaticComplexity
    private def scan_colon(start : Int32, line : Int32, col : Int32) : Token
      if current_char == ':'
        advance
        return make_token(TokenKind::ColonColon, "::", line, col)
      end
      c = current_char
      if c.ascii_letter? || c == '_'
        while !at_end? && ident_continue?(current_char)
          advance
        end
        advance if current_char == '?' || current_char == '!'
        return make_token(TokenKind::Symbol, lexeme_from(start), line, col)
      end
      if c == '"' || c == '\''
        q = c
        advance
        while !at_end?
          if current_char == '\\'
            advance
            advance unless at_end?
            next
          end
          break if current_char == q
          advance
        end
        advance unless at_end? # closing quote
        return make_token(TokenKind::Symbol, lexeme_from(start), line, col)
      end
      make_token(TokenKind::Colon, ":", line, col)
    end

    private def scan_dot(start : Int32, line : Int32, col : Int32) : Token
      if current_char == '.'
        advance
        if current_char == '.'
          advance
          return make_token(TokenKind::RangeExcl, "...", line, col)
        end
        return make_token(TokenKind::RangeIncl, "..", line, col)
      end
      make_token(TokenKind::Dot, ".", line, col)
    end

    private def scan_eq(start : Int32, line : Int32, col : Int32) : Token
      if current_char == '='
        advance
        # `===` is one token so it gets its own precedence and
        # `def ===(x)` reaches U017's rejection.
        if current_char == '='
          advance
          return make_token(TokenKind::TripleEq, "===", line, col)
        end
        return make_token(TokenKind::EqEq, "==", line, col)
      end
      if current_char == '~'
        # `=~` is one token so it gets its own precedence and
        # `x.=~(y)` parses as a method call.
        advance
        return make_token(TokenKind::EqTilde, "=~", line, col)
      end
      if current_char == '>'
        advance
        return make_token(TokenKind::HashRocket, "=>", line, col)
      end
      make_token(TokenKind::Eq, "=", line, col)
    end

    private def scan_lt(start : Int32, line : Int32, col : Int32) : Token
      if current_char == '<'
        advance
        return make_token(TokenKind::Shl, "<<", line, col)
      end
      if current_char == '='
        advance
        if current_char == '>'
          advance
          return make_token(TokenKind::Spaceship, "<=>", line, col)
        end
        return make_token(TokenKind::LtE, "<=", line, col)
      end
      make_token(TokenKind::Lt, "<", line, col)
    end

    private def scan_gt(start : Int32, line : Int32, col : Int32) : Token
      if current_char == '>'
        advance
        return make_token(TokenKind::Shr, ">>", line, col)
      end
      if current_char == '='
        advance
        return make_token(TokenKind::GtE, ">=", line, col)
      end
      make_token(TokenKind::Gt, ">", line, col)
    end

    private def scan_amp(start : Int32, line : Int32, col : Int32) : Token
      if current_char == '&'
        advance
        return match('=') ? make_token(TokenKind::AndAssign, "&&=", line, col) : make_token(TokenKind::AndAnd, "&&", line, col)
      end
      if current_char == '.'
        advance
        return make_token(TokenKind::SafeNav, "&.", line, col)
      end
      make_token(TokenKind::Amp, "&", line, col)
    end

    # Closing delimiters for `%w` and `%i` literals. These four pairs
    # nest; any other delimiter closes with the same character.
    PERCENT_CLOSERS = {'(' => ')', '[' => ']', '{' => '}', '<' => '>'} of Char => Char

    private def percent_literal_starts_here? : Bool
      c = current_char
      return false unless c == 'w' || c == 'i'
      delim = peek_next
      return false if delim == '\0' || delim.ascii_alphanumeric? || delim == '_' || delim.ascii_whitespace?
      true
    end

    # Scans a `%w` or `%i` literal's raw body up to its closing
    # delimiter. A backslash escapes the next character; the parser
    # splits the words and treats `\ ` as a literal space.
    private def scan_percent_literal(start : Int32, line : Int32, col : Int32) : Token
      kind_char = advance # 'w' or 'i'
      open_delim = advance
      close_delim = PERCENT_CLOSERS[open_delim]? || open_delim
      nesting = PERCENT_CLOSERS.has_key?(open_delim)
      depth = 1
      body_start = @pos
      while !at_end?
        c = current_char
        if c == '\\'
          advance
          advance unless at_end?
          next
        end
        if nesting && c == open_delim
          depth += 1
          advance
          next
        end
        if c == close_delim
          depth -= 1
          if depth == 0
            content = @source[body_start, @pos - body_start]
            advance # closing delimiter
            kind = kind_char == 'w' ? TokenKind::PercentWords : TokenKind::PercentSymbols
            return make_token(kind, content, line, col)
          end
          advance
          next
        end
        advance
      end
      make_token(TokenKind::Error, "unterminated %#{kind_char}#{open_delim}...", line, col)
    end

    # Whether `<<` opens a heredoc rather than shifting. The
    # identifier must be uppercase or quoted, so `x << y` is never
    # misread. `<<~ID` and `<<-ID` qualify anywhere; bare `<<ID` only
    # after a token that can't end an expression, as for `/`. Only one
    # heredoc per line is supported; a second opener scans as `<<`.
    private def heredoc_starts_here? : Bool
      return false unless current_char == '<'
      third = peek_at(1)
      case third
      when '~', '-'
        id_start = peek_at(2)
        id_start.ascii_uppercase? || id_start == '"' || id_start == '\''
      when '"', '\''
        !EXPR_END_KINDS.includes?(@prev_kind)
      else
        third.ascii_uppercase? && !EXPR_END_KINDS.includes?(@prev_kind)
      end
    end

    # Scans a heredoc opener (`<<~ID`, `<<-ID` or `<<ID`, the ID
    # optionally quoted) and tokenizes the whole heredoc from the
    # following lines, without moving the cursor. Scanning resumes on
    # the opener's line; the body is skipped when reached.
    # ameba:disable Metrics/CyclomaticComplexity
    private def scan_heredoc_opener(start : Int32, line : Int32, col : Int32) : Token
      advance # second '<'
      squiggly = false
      dash = false
      if current_char == '~'
        squiggly = true
        advance
      elsif current_char == '-'
        dash = true
        advance
      end
      quote = current_char == '"' || current_char == '\'' ? current_char : nil
      advance if quote
      id_start = @pos
      while !at_end? && ident_continue?(current_char)
        advance
      end
      id = lexeme_from(id_start)
      if quote
        return make_token(TokenKind::Error, "unterminated heredoc identifier", line, col) unless current_char == quote
        advance
      end
      interpolate = quote != '\''
      allow_indented_terminator = squiggly || dash

      header_line = @line
      line_end = @source.index('\n', @pos) || @source.size
      body_start = line_end + 1 > @source.size ? @source.size : line_end + 1

      cursor = body_start
      terminator_at = nil.as(Int32?)
      after_terminator = @source.size
      loop do
        this_line_nl = @source.index('\n', cursor)
        this_line_end = this_line_nl || @source.size
        candidate = @source[cursor, this_line_end - cursor]
        check = allow_indented_terminator ? candidate.strip : candidate
        if check == id
          terminator_at = cursor
          after_terminator = this_line_nl ? this_line_nl + 1 : @source.size
          break
        end
        break if this_line_nl.nil? # ran off the end, never found it
        cursor = this_line_nl + 1
      end

      term_at = terminator_at
      if term_at.nil?
        return make_token(TokenKind::Error, "unterminated heredoc: no closing `#{id}`", line, col)
      end

      body_raw = @source[body_start, term_at - body_start]
      body_end_pos = after_terminator
      body = squiggly ? dedent_heredoc_body(body_raw) : body_raw

      @pending_heredoc_skip_at = line_end
      @pending_heredoc_skip_to_pos = body_end_pos
      @pending_heredoc_skip_to_line = header_line + 1 + body_raw.each_char.count { |char| char == '\n' } + 1

      if interpolate
        tokens = Lexer.new(body, @filename).heredoc_body_tokens(header_line + 1)
        first = tokens[0]
        fixed_first = Token.new(first.kind, first.lexeme, line, col, @space_before, first.regex_flags)
        @pending_tokens.concat(tokens[1..])
        fixed_first
      else
        Token.new(TokenKind::String, "'" + escape_single_quoted(body) + "'", line, col, @space_before)
      end
    end

    # Tokenizes an interpolating heredoc body, which is this lexer's
    # whole source, into a String token or a StringPart...StringEnd
    # sequence, as for a double-quoted string. `start_line` is the
    # body's first line in the script, for diagnostics.
    def heredoc_body_tokens(start_line : Int32) : Array(Token)
      @line = start_line
      tokens = [] of Token
      tok = scan_heredoc_first_chunk
      tokens << tok
      until tok.kind.in?(TokenKind::String, TokenKind::StringEnd, TokenKind::EOF, TokenKind::Error)
        tok = next_token
        tokens << tok
      end
      tokens
    end

    # Scans the body's first chunk: the whole body as a String token,
    # wrapped in `"` as the parser expects, or a StringPart up to the
    # first `#{`.
    private def scan_heredoc_first_chunk : Token
      line = @line
      col = @column
      start = @pos
      while !at_end?
        c = current_char
        if c == '\\'
          advance
          advance unless at_end?
          next
        end
        if c == '#' && peek_next == '{'
          content = @source[start, @pos - start]
          advance # #
          advance # {
          @in_interp = true
          @interp_brace_depth = 1
          @interp_kind = InterpKind::Heredoc
          return make_token(TokenKind::StringPart, content, line, col)
        end
        advance
      end
      content = @source[start, @pos - start]
      make_token(TokenKind::String, "\"" + content + "\"", line, col)
    end

    # Squiggly (`<<~ID`) dedent: strips the minimum common leading
    # whitespace found across every non-blank body line. A blank
    # (whitespace-only) line never participates in that minimum and is
    # dedented by whatever amount the real lines settled on, same as
    # real Ruby.
    private def dedent_heredoc_body(text : String) : String
      lines = text.split('\n')
      min_indent = nil.as(Int32?)
      lines.each do |line_text|
        next if line_text.strip.empty?
        indent = 0
        line_text.each_char do |char|
          break unless char == ' ' || char == '\t'
          indent += 1
        end
        current_min = min_indent
        min_indent = indent if current_min.nil? || indent < current_min
      end
      mi = min_indent
      return text if mi.nil? || mi == 0
      String.build do |io|
        lines.each_with_index do |line_text, idx|
          io << (line_text.size >= mi ? line_text[mi..] : line_text.lstrip(" \t"))
          io << '\n' unless idx == lines.size - 1
        end
      end
    end

    # Escapes `\` and `'` so the body survives as a `'...'` lexeme,
    # which the parser un-escapes.
    private def escape_single_quoted(text : String) : String
      String.build do |io|
        text.each_char do |char|
          io << '\\' if char == '\\' || char == '\''
          io << char
        end
      end
    end
  end
end
