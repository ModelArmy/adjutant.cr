require "./token"

module Adjutant
  # Lexer: converts source text into a stream of Tokens.
  #
  # Call #next_token repeatedly until EOF, or use #tokenize to
  # collect all tokens at once (useful for testing).
  class Lexer
    # Which literal kind an in-progress `#{...}` interpolation belongs
    # to, so `continue_interp` (resumed after the interpolation's
    # closing `}`) knows whether it's looking for a closing `"` (Str)
    # or a closing `/` plus trailing flags (Regex).
    enum InterpKind
      Str
      Regex
    end

    getter filename : String

    # The full source text, already read eagerly in the constructor.
    # Exposed so `SourceMap` can retain it for diagnostic rendering —
    # previously it was dropped once tokens were produced, leaving
    # nothing to quote by the time anything failed.
    getter source : String

    # Primary constructor - reads the IO eagerly into a String.
    # Random access (peek, backtrack, lexeme slicing) requires the full
    # source in memory; true streaming would add complexity for no gain
    # since scripts are short.
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
      # Last significant (non-space, non-comment) token kind emitted,
      # read by `regex_starts_here?` to disambiguate a bare `/` between
      # division and the start of a regex literal — see that method's
      # own comment for the actual heuristic. Nil only before the very
      # first token of the source, which is itself a "start of
      # expression" position (same bucket as Newline).
      @prev_kind = nil.as(TokenKind?)
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
      if @in_interp && @interp_brace_depth == 0
        return continue_interp
      end

      # Set once per token, read by `make_token` for every token scanned
      # below (including nested calls like `scan_number`/`scan_string`
      # that each call `make_token` themselves) — an instance variable
      # rather than a threaded parameter, since threading a single bit
      # through every `scan_*`/`make_token` call site (30+) would be a
      # far larger, noisier diff for the same result. Safe as instance
      # state because it's write-once-then-read within a single
      # `next_token` call, same lifecycle as `line`/`col`/`start` below.
      @space_before = skip_whitespace_and_comments

      line = @line
      col = @column
      start = @pos

      return make_token(TokenKind::EOF, "", line, col) if at_end?

      c = advance
      return make_token(TokenKind::Newline, "\n", line, col) if c == '\n'

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

    # General n-ahead lookahead, needed for exponent scanning
    # (`e`/`E`, optional `+`/`-`, then a digit — up to 2 characters
    # ahead of the `e` itself). `peek_next` (offset 1) is kept as-is
    # since it's already used elsewhere and reads slightly clearer at
    # its one-ahead call sites.
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

    # Returns true iff at least one whitespace character or comment was
    # actually consumed — i.e. whether the token about to be scanned is
    # preceded by space, the fact `next_token` stashes into
    # `@space_before` for `make_token` to attach to that token. A
    # comment counts as "space" for this purpose: `x#comment\ny` and
    # `x y` are equivalent from the parser's point of view (this only
    # matters within a single line anyway, since a comment always runs
    # to end-of-line and a real Newline token follows).
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

    # Resume scanning a string or regex body after the closing } of an
    # interpolation. Dispatches on @interp_kind (set when the literal
    # was first opened, in scan_string/scan_regex) since a string's
    # terminator is a bare `"` while a regex's is `/` followed by
    # optional trailing flags — two different shapes, not something a
    # single shared terminator char could express.
    private def continue_interp : Token
      case @interp_kind
      when InterpKind::Regex
        continue_interp_regex
      else
        continue_interp_string
      end
    end

    private def continue_interp_string : Token
      @in_interp = false
      # Resuming right after the interpolation's closing `}` — never
      # "preceded by space" in the sense any parser rule cares about,
      # regardless of whatever `@space_before` was left holding from
      # the last real `next_token` call (the `}` itself). Set
      # explicitly rather than left stale.
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

    # Main scan dispatch — called after consuming the first character `c`.
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
        match('=') ? make_token(TokenKind::NEq, "!=", line, col) : make_token(TokenKind::Bang, "!", line, col)
      when '<'
        scan_lt(start, line, col)
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
        match('=') ? make_token(TokenKind::PercentEq, "%=", line, col) : make_token(TokenKind::Percent, "%", line, col)
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

    # Continues a run of ASCII digits, allowing a single `_` wherever
    # it sits strictly between two digits. IMPORTANT: at every real
    # call site (scan_number's initial call, and after consuming `.`
    # or `e`/sign for the fractional/exponent parts), the FIRST digit
    # of the run has already been consumed by the caller before this
    # runs — @pos is already sitting one character past it. This
    # method must therefore check for a trailing `_`+digit FIRST,
    # before requiring `current_char` itself to be a fresh digit —
    # checking `current_char.ascii_number?` as a loop's leading
    # condition (as an earlier version of this method did) fails
    # immediately in the common case where current_char is already the
    # SECOND digit or beyond, silently consuming nothing and leaving
    # the rest of the run (e.g. "_000_000" after an already-consumed
    # leading "1") for the next token entirely — caught via a failing
    # spec (pairs("1_000_000") — see lexer_spec.cr), not by
    # inspection.
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

      # Exponent — `e`/`E`, optional `+`/`-`, then at least one digit.
      # Valid with OR without a preceding `.` (`1e20` is a bare integer
      # digit run immediately followed by an exponent — no decimal
      # point anywhere — and is still a Float in real Ruby, confirmed
      # via Ruby's own literals doc: `1234e-2` is listed as one of
      # three equivalent Float-literal forms for the same value,
      # alongside `12.34` and `1.234E1`). This is why exponent
      # scanning is unconditional here rather than nested inside the
      # `is_float` branch above — the ONLY thing that makes a numeric
      # literal a Float is having a `.` OR an exponent, not needing
      # both.
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

    # Trailing flag letters on a regex literal's closing `/` — real
    # Ruby's `i`/`m`/`x` (IGNORECASE/MULTILINE/EXTENDED). Any other
    # letter immediately after the closing `/` is a real Ruby error
    # ("unknown regexp option") in the general case, but scoped v1
    # here just stops consuming at the first unrecognized letter and
    # leaves it for the next token — good enough to not choke on
    # legitimate follow-on code like `/abc/.match(x)`, and a stricter
    # "unknown flag" diagnostic is a small follow-up, not a blocker
    # for v1.
    private def scan_regex_flags : String
      fstart = @pos
      while !at_end? && "imx".includes?(current_char)
        advance
      end
      @source[fstart, @pos - fstart]
    end

    # Scans a /pattern/flags literal, starting right after the opening
    # `/` has already been consumed by `scan` (mirrors scan_string's
    # own contract). Interpolation (`#{...}`) is supported exactly
    # like double-quoted strings — real Ruby regex literals interpolate
    # too (see "Regexp#to_s - interpolation" in the mruby fixture) — by
    # switching into the same @in_interp machinery, just tagged
    # InterpKind::Regex so `continue_interp` resumes looking for a
    # closing `/` instead of `"`.
    #
    # Escape sequences inside the pattern are NOT decoded here (unlike
    # decode_string_escapes for string literals) — a regex pattern's
    # backslash sequences (`\d`, `\bfoo\b`, `\A`, `\1`) belong to the
    # regex engine's own syntax, not Adjutant's string-escape table, so
    # the raw source text is exactly what Regexp.new must receive.
    # `\/` is left as two characters (backslash + slash) rather than
    # collapsed — PCRE2 (and Onigmo) both treat a backslash-escaped
    # delimiter as a no-op escape of a literal `/`, so passing it
    # through unmodified matches a bare `/` correctly without
    # Adjutant's lexer needing to understand regex escape semantics
    # itself.
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

    # Ruby-style regex/division disambiguation for a bare `/`. Ruby's
    # real lexer decides based on parser state (expr-beg vs expr-end);
    # Adjutant has no such state machine, so this approximates it from
    # the previous token alone, which covers the common cases:
    #
    #   - If the previous token is something that CAN end an
    #     expression (a literal, identifier, closing bracket, `end`,
    #     etc.) then `/` defaults to division — `x / y`, `arr[0] / 2`.
    #   - Otherwise (after `(`, `,`, an operator, a keyword like
    #     `return`/`if`/`and`, a newline, or at the very start of the
    #     source) `/` starts a regex literal — `foo(/abc/)`, `if /x/`.
    #   - The one genuinely ambiguous real-Ruby case is a bare
    #     identifier immediately followed by `/`, since the identifier
    #     might be a local variable (division) or a method call taking
    #     a regex argument (`grep /foo/`). Real Ruby breaks the tie on
    #     spacing: space before `/` but NOT after it means "argument",
    #     i.e. regex; anything else means division. That heuristic is
    #     applied here too, via a one-character lookahead.
    #
    # Deliberately does not attempt full expr-beg/expr-end tracking —
    # that would require threading parser-level context back into the
    # lexer. This is a real, scoped simplification (worth a SCOPE.md
    # line if a script turns up that it gets wrong), not a silent gap.
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

    # Bounded lookahead confirming there's an actual closing `/` to be
    # found before end-of-line/end-of-source, without consuming
    # anything. Needed alongside the previous-token heuristic above:
    # that heuristic alone treated every bare `/` at the very start of
    # a line (or after `def`, `(`, etc.) as a regex opener, which is
    # right for `/abc/` but wrong for the common "just division/an
    # operator token, nothing regex-shaped here at all" case — e.g. a
    # lone `/` or `/=` as an entire source (real lexer-spec cases),
    # or `def /(o)` defining the `/` operator method itself. Real
    # regex literals never span a newline unescaped (single-line
    # `/pattern/` — the `%r{...}` multiline form is deliberately
    # deferred, see SCOPE.md), so scanning to the next unescaped `/`
    # or newline, whichever comes first, is a cheap and accurate
    # feasibility check: no closing `/` on this line means it was
    # never a regex to begin with.
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

    # Token kinds after which a bare `/` is division, not the start of
    # a regex literal — i.e. kinds that can end an expression. Every
    # kind NOT in this set (operators, keywords like `return`/`if`,
    # opening brackets, `,`, `;`, Newline, and start-of-source) is
    # treated as "expression is about to begin", where `/` starts a
    # regex. TokenKind::Identifier is handled separately in
    # `regex_starts_here?` (see its own comment) since it's genuinely
    # ambiguous rather than falling cleanly into either bucket.
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
        # A third `=` makes `===` — checked here, not given its own
        # PRECEDENCE table entry: `"==="` has no meaning as a general
        # infix expression in Adjutant (case/when's real dispatch is
        # compiler-generated, not parsed from `a === b` script syntax
        # — see compile_case), so this token exists ONLY so `def
        # ===(x)` can parse far enough to reach U017's clean, named
        # rejection instead of splitting into EqEq + a stray Eq and
        # failing with a confusing, unrelated-looking P002 partway
        # through the method body. See SCOPE.md's Will Fix entry for
        # the full reasoning.
        if current_char == '='
          advance
          return make_token(TokenKind::TripleEq, "===", line, col)
        end
        return make_token(TokenKind::EqEq, "==", line, col)
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
  end
end
