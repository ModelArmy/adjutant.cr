require "../spec_helper"

module Adjutant
  # Helper: tokenize source and return kinds only (excluding EOF)
  private def self.kinds(source : String) : Array(TokenKind)
    Lexer.new(source).tokenize.map(&.kind).reject { |k| k == TokenKind::EOF }
  end

  # Helper: tokenize and return [kind, lexeme] pairs (excluding EOF)
  private def self.pairs(source : String) : Array({TokenKind, String})
    Lexer.new(source).tokenize
      .reject { |t| t.kind == TokenKind::EOF }
      .map { |t| {t.kind, t.lexeme} }
  end

  # Helper: tokenize and return [kind, space_before?] pairs (excluding EOF)
  private def self.spacing(source : String) : Array({TokenKind, Bool})
    Lexer.new(source).tokenize
      .reject { |t| t.kind == TokenKind::EOF }
      .map { |t| {t.kind, t.space_before?} }
  end

  describe Lexer do
    describe "EOF and empty input" do
      it "returns EOF for empty source" do
        tok = Lexer.new("").next_token
        tok.kind.should eq TokenKind::EOF
      end

      it "returns EOF repeatedly after end" do
        lex = Lexer.new("")
        lex.next_token.kind.should eq TokenKind::EOF
        lex.next_token.kind.should eq TokenKind::EOF
      end
    end

    describe "whitespace and comments" do
      it "skips spaces and tabs" do
        kinds("   \t  ").should be_empty
      end

      it "emits Newline for line breaks" do
        kinds("\n").should eq [TokenKind::Newline]
      end

      it "skips line comments" do
        kinds("# this is a comment").should be_empty
      end

      it "skips comment but preserves newline after" do
        kinds("# comment\n").should eq [TokenKind::Newline]
      end
    end

    # `Token#space_before?`, added alongside the whitespace-sensitive
    # parser rules it now backs (`eq -1, -1` vs `n - 1`, `-0.0.to_s`
    # literal fusion, `eq (6/3), 2`) — see operators/parser_spec.cr for
    # the actual disambiguation behavior these tokens enable. This block
    # only tests the LEXER's own responsibility: does each token
    # correctly report whether whitespace (or a comment) immediately
    # preceded it.
    describe "space_before? tracking" do
      it "is false for the very first token in the source" do
        spacing("foo").should eq [{TokenKind::Identifier, false}]
      end

      it "is false when a token immediately follows another with no gap" do
        spacing("a+b").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Plus, false},
          {TokenKind::Identifier, false},
        ]
      end

      it "is true for a token preceded by a single space" do
        spacing("a + b").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Plus, true},
          {TokenKind::Identifier, true},
        ]
      end

      it "is true regardless of how much whitespace precedes (space run collapses to one bit)" do
        spacing("a    +\t\tb").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Plus, true},
          {TokenKind::Identifier, true},
        ]
      end

      it "distinguishes space-before-only from space-on-both-sides for a single operator" do
        # The exact shape parse_identifier_or_call's adjacency check
        # depends on: space before the operator, none after.
        spacing("a -1").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Minus, true},
          {TokenKind::Integer, false},
        ]
      end

      it "attributes space-before-a-comment to the token the comment precedes, not the token after the following newline" do
        # skip_whitespace_and_comments consumes the comment (reporting
        # `true`) as part of scanning the NEXT token after it — which
        # is the Newline itself (`#comment` runs up to but does not
        # consume the `\n`). `b`, scanned on the following call, has
        # nothing directly before it (the `\n` was its own token, not
        # whitespace `b` sits inside), so it correctly gets `false` —
        # same reasoning as the newline-token-boundary test below.
        spacing("a #comment\nb").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Newline, true},
          {TokenKind::Identifier, false},
        ]
      end

      it "reports the Newline as space-before even when the comment immediately abuts the prior token" do
        # Isolates the comment branch of skip_whitespace_and_comments
        # from any literal-whitespace character before it — `a` and
        # `#` here have no space between them at all, only the comment
        # itself counts as the "space" that precedes the Newline.
        spacing("a#comment\nb").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Newline, true},
          {TokenKind::Identifier, false},
        ]
      end

      it "does not mark a token as space-before merely for following a Newline token" do
        # `\n` is consumed as its own token by next_token's direct
        # `c == '\n'` check, not absorbed into skip_whitespace_and_comments
        # the way spaces/tabs/comments are — so it does NOT cause the
        # following token to report space_before?. This is a real,
        # deliberate asymmetry (space and comments are "invisible"
        # separators the lexer swallows; a newline is a token in its
        # own right), not an oversight — every whitespace-sensitive
        # parser rule this field backs only cares about same-line
        # adjacency anyway.
        spacing("a\nb").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Newline, false},
          {TokenKind::Identifier, false},
        ]
      end

      it "resets per token — space before one token does not leak into the next" do
        spacing("a + b+c").should eq [
          {TokenKind::Identifier, false},
          {TokenKind::Plus, true},
          {TokenKind::Identifier, true},
          {TokenKind::Plus, false},
          {TokenKind::Identifier, false},
        ]
      end

      it "is false for a token resumed right after a string interpolation's closing brace" do
        # continue_interp_string is a separate code path from
        # next_token's normal skip_whitespace_and_comments call (see
        # Lexer#continue_interp_string) — this confirms it explicitly
        # resets @space_before rather than leaking whatever the
        # closing `}` token happened to carry.
        tokens = Lexer.new(%("a\#{x} b")).tokenize.reject { |t| t.kind == TokenKind::EOF }
        string_end = tokens.find { |t| t.kind == TokenKind::StringEnd }
        string_end.should_not be_nil
        string_end.not_nil!.space_before?.should be_false
      end
    end

    describe "identifiers and keywords" do
      it "scans a simple identifier" do
        pairs("foo").should eq [{TokenKind::Identifier, "foo"}]
      end

      it "scans an identifier with underscore" do
        pairs("my_var").should eq [{TokenKind::Identifier, "my_var"}]
      end

      it "scans a predicate method name" do
        pairs("empty?").should eq [{TokenKind::Identifier, "empty?"}]
      end

      it "scans a bang method name" do
        pairs("save!").should eq [{TokenKind::Identifier, "save!"}]
      end

      it "scans a constant (uppercase start)" do
        pairs("MyClass").should eq [{TokenKind::Constant, "MyClass"}]
      end

      it "scans all keywords" do
        KEYWORDS.each do |word, kind|
          result = pairs(word)
          result.size.should eq(1), "expected 1 token for #{word.inspect}"
          result[0][0].should eq(kind), "expected #{kind} for #{word.inspect}"
        end
      end
    end

    describe "variables" do
      it "scans instance variable" do
        pairs("@name").should eq [{TokenKind::IVar, "@name"}]
      end

      it "scans class variable" do
        pairs("@@count").should eq [{TokenKind::CVar, "@@count"}]
      end

      it "scans global variable" do
        pairs("$stdout").should eq [{TokenKind::GVar, "$stdout"}]
      end
    end

    describe "integer literals" do
      it "scans a decimal integer" do
        pairs("42").should eq [{TokenKind::Integer, "42"}]
      end

      it "scans a negative-looking sequence as minus + integer" do
        pairs("-7").should eq [{TokenKind::Minus, "-"}, {TokenKind::Integer, "7"}]
      end

      it "scans a hex literal" do
        pairs("0xFF").should eq [{TokenKind::Integer, "0xFF"}]
      end

      # Underscore separators, added 2026-07-21 alongside float exponent
      # support (see SCOPE.md's "Float literals don't support exponent
      # notation or underscore separators" entry — same Lexer#
      # scan_digit_run mechanism serves both integer and float
      # literals, since Ruby's own grammar allows underscores in both).
      it "scans a decimal integer with underscore separators" do
        pairs("1_000_000").should eq [{TokenKind::Integer, "1_000_000"}]
      end

      it "does not consume a trailing underscore as part of the integer" do
        # Real Ruby rejects a trailing underscore (`1000_` is a syntax
        # error) — Adjutant doesn't need to raise a specific error for
        # this shape, but the LEXER must not silently absorb the `_`
        # into the number; scan_digit_run leaves it behind because it's
        # not followed by a digit, so it becomes its own (likely
        # nonsensical, parse-error-producing) token instead.
        pairs("100_").should eq [{TokenKind::Integer, "100"}, {TokenKind::Identifier, "_"}]
      end

      it "does not consume a doubled underscore as part of the integer" do
        pairs("1__000").should eq [{TokenKind::Integer, "1"}, {TokenKind::Identifier, "__000"}]
      end

      it "does not consume a leading underscore as part of the integer" do
        # `_1000` lexes as a single identifier token, same as real
        # Ruby (a leading underscore makes it a valid local-variable-
        # style identifier, not a number at all) — scan_number is never
        # even entered here since the lexer's own dispatch on the
        # first character routes '_' to identifier scanning, not
        # number scanning; included here for completeness of the
        # underscore-shape coverage, not because scan_number itself is
        # exercised.
        pairs("_1000").should eq [{TokenKind::Identifier, "_1000"}]
      end
    end

    describe "float literals" do
      it "scans a float" do
        pairs("3.14").should eq [{TokenKind::Float, "3.14"}]
      end

      it "does not treat 3.. as float" do
        kinds("3..").should eq [TokenKind::Integer, TokenKind::RangeIncl]
      end

      # Exponent notation, added 2026-07-21 (see SCOPE.md's "Float
      # literals don't support exponent notation or underscore
      # separators" entry). Shapes below are drawn directly from
      # mruby's test/t/float.rb and Ruby's own literals doc (which
      # lists `12.34`, `1234e-2`, and `1.234E1` as three equivalent
      # forms of the same value).
      it "scans a float with a lowercase exponent and no sign" do
        pairs("1e20").should eq [{TokenKind::Float, "1e20"}]
      end

      it "scans a float with an uppercase exponent" do
        pairs("1.234E1").should eq [{TokenKind::Float, "1.234E1"}]
      end

      it "scans a float with a negative exponent, with a decimal point" do
        pairs("1.0e-400").should eq [{TokenKind::Float, "1.0e-400"}]
      end

      it "scans a float with a negative exponent, no decimal point at all" do
        # This is the case that most needed scan_number restructured —
        # a bare digit run immediately followed by an exponent, with NO
        # `.` anywhere, is still a Float in real Ruby (1234e-2 from
        # Ruby's own literals doc). The old implementation could only
        # ever reach TokenKind::Float through the `.`-then-digits
        # branch.
        pairs("1234e-2").should eq [{TokenKind::Float, "1234e-2"}]
      end

      it "scans a float with a positive exponent sign" do
        pairs("4e+38").should eq [{TokenKind::Float, "4e+38"}]
      end

      it "scans a float with underscore separators in the exponent's mantissa" do
        pairs("1_000.5").should eq [{TokenKind::Float, "1_000.5"}]
      end

      it "does not treat a bare 'e' with no following digit as an exponent" do
        # `1e` with nothing (or a non-digit) after the e is not a valid
        # exponent — must not consume the `e` into the number at all,
        # leaving it to lex separately (as the start of an identifier).
        pairs("1e").should eq [{TokenKind::Integer, "1"}, {TokenKind::Identifier, "e"}]
      end

      it "does not treat 'e' followed by a sign with no digit as an exponent" do
        pairs("1e+").should eq [{TokenKind::Integer, "1"}, {TokenKind::Identifier, "e"}, {TokenKind::Plus, "+"}]
      end
    end

    describe "string literals" do
      it "scans a single-quoted string" do
        pairs("'hello'").should eq [{TokenKind::String, "'hello'"}]
      end

      it "scans a double-quoted string without interpolation" do
        pairs("\"hello\"").should eq [{TokenKind::String, "\"hello\""}]
      end

      it "scans an escaped quote inside a string" do
        pairs("\"say \\\"hi\\\"\"").should eq [{TokenKind::String, "\"say \\\"hi\\\"\""}]
      end
    end

    describe "string interpolation" do
      it "splits an interpolated string into parts" do
        tokens = Lexer.new("\"hello \#{name}!\"").tokenize.reject { |t| t.kind == TokenKind::EOF }
        kinds_only = tokens.map(&.kind)
        kinds_only.should eq [
          TokenKind::StringPart,
          TokenKind::Identifier,
          TokenKind::InterpEnd,
          TokenKind::StringEnd,
        ]
      end

      it "captures the pre-interpolation content" do
        tokens = Lexer.new("\"hello \#{name}\"").tokenize
        part = tokens.find { |t| t.kind == TokenKind::StringPart }
        part.should_not be_nil
        part.not_nil!.lexeme.should eq "hello "
      end

      it "captures the post-interpolation content" do
        tokens = Lexer.new("\"hi \#{x}!\"").tokenize
        tail = tokens.find { |t| t.kind == TokenKind::StringEnd }
        tail.should_not be_nil
        tail.not_nil!.lexeme.should eq "!"
      end
    end

    describe "symbols" do
      it "scans a simple symbol" do
        pairs(":ok").should eq [{TokenKind::Symbol, ":ok"}]
      end

      it "scans a symbol with predicate suffix" do
        pairs(":empty?").should eq [{TokenKind::Symbol, ":empty?"}]
      end

      it "scans a quoted symbol" do
        pairs(":\"hello world\"").should eq [{TokenKind::Symbol, ":\"hello world\""}]
      end

      it "distinguishes colon from symbol" do
        kinds("a:").should eq [TokenKind::Identifier, TokenKind::Colon]
      end
    end

    describe "operators and punctuation" do
      {
        "("   => TokenKind::LParen,
        ")"   => TokenKind::RParen,
        "["   => TokenKind::LBracket,
        "]"   => TokenKind::RBracket,
        ","   => TokenKind::Comma,
        ";"   => TokenKind::Semi,
        "+"   => TokenKind::Plus,
        "-"   => TokenKind::Minus,
        "*"   => TokenKind::Star,
        "/"   => TokenKind::Slash,
        "%"   => TokenKind::Percent,
        "^"   => TokenKind::Caret,
        "~"   => TokenKind::Tilde,
        "?"   => TokenKind::Question,
        "|"   => TokenKind::Pipe,
        "="   => TokenKind::Eq,
        "=="  => TokenKind::EqEq,
        "!="  => TokenKind::NEq,
        "<"   => TokenKind::Lt,
        "<="  => TokenKind::LtE,
        ">"   => TokenKind::Gt,
        ">="  => TokenKind::GtE,
        "<=>" => TokenKind::Spaceship,
        "&&"  => TokenKind::AndAnd,
        "||"  => TokenKind::OrOr,
        "<<"  => TokenKind::Shl,
        ">>"  => TokenKind::Shr,
        "=>"  => TokenKind::HashRocket,
        ".."  => TokenKind::RangeIncl,
        "..." => TokenKind::RangeExcl,
        "&."  => TokenKind::SafeNav,
        "::"  => TokenKind::ColonColon,
        "+="  => TokenKind::PlusEq,
        "-="  => TokenKind::MinusEq,
        "*="  => TokenKind::StarEq,
        "/="  => TokenKind::SlashEq,
        "%="  => TokenKind::PercentEq,
        "||=" => TokenKind::OrAssign,
        "&&=" => TokenKind::AndAssign,
        "->"  => TokenKind::Arrow,
      }.each do |src, expected_kind|
        it "scans #{src.inspect}" do
          kinds(src).should eq [expected_kind]
        end
      end
    end

    describe "source position tracking" do
      it "reports correct line for a token on line 1" do
        tok = Lexer.new("foo").next_token
        tok.line.should eq 1
      end

      it "reports correct line for a token after a newline" do
        tokens = Lexer.new("foo\nbar").tokenize
        bar = tokens.find { |t| t.lexeme == "bar" }
        bar.should_not be_nil
        bar.not_nil!.line.should eq 2
      end

      it "reports correct column" do
        tokens = Lexer.new("  foo").tokenize
        foo = tokens.find { |t| t.lexeme == "foo" }
        foo.should_not be_nil
        foo.not_nil!.column.should eq 3
      end
    end

    describe "a realistic snippet" do
      it "tokenizes a method definition" do
        src = "def greet(name)\n  puts name\nend"
        k = kinds(src)
        k.should eq [
          TokenKind::KwDef,
          TokenKind::Identifier,
          TokenKind::LParen,
          TokenKind::Identifier,
          TokenKind::RParen,
          TokenKind::Newline,
          TokenKind::Identifier,
          TokenKind::Identifier,
          TokenKind::Newline,
          TokenKind::KwEnd,
        ]
      end
    end

    describe "UTF-8 support" do
      it "lexes a string containing UTF-8 characters" do
        pairs(%("héllo wörld")).should eq [{TokenKind::String, %("héllo wörld")}]
      end

      it "lexes a string containing CJK characters" do
        pairs(%("日本語")).should eq [{TokenKind::String, %("日本語")}]
      end

      it "lexes a string containing emoji" do
        pairs(%("hello 🌍")).should eq [{TokenKind::String, %("hello 🌍")}]
      end

      it "skips a comment containing UTF-8 characters" do
        kinds("# こんにちは\n42").should eq [TokenKind::Newline, TokenKind::Integer]
      end

      it "tracks line numbers correctly across multi-byte characters" do
        tokens = Lexer.new("# héllo\nfoo").tokenize
        foo = tokens.find { |t| t.lexeme == "foo" }
        foo.should_not be_nil
        foo.not_nil!.line.should eq 2
      end

      # UTF-8 identifier characters are not yet supported in symbols or
      # identifiers — ident_continue? uses ascii_alphanumeric? by design.
      # This test asserts current behaviour: the non-ASCII suffix becomes
      # an Error token. Remove once Unicode identifiers are supported.
      it "produces an error token for non-ASCII characters in a symbol" do
        result = pairs(":café")
        result[0].should eq({TokenKind::Symbol, ":caf"})
        result[1][0].should eq TokenKind::Error
      end
    end

    describe "IO constructor" do
      it "tokenizes source from a String IO" do
        io = IO::Memory.new("x = 42")
        tokens = Lexer.new(io).tokenize.reject { |t| t.kind == TokenKind::EOF }
        tokens.map(&.kind).should eq [
          TokenKind::Identifier,
          TokenKind::Eq,
          TokenKind::Integer,
        ]
      end

      it "reads multi-line source from IO" do
        io = IO::Memory.new("foo\nbar")
        tokens = Lexer.new(io).tokenize.reject { |t| t.kind == TokenKind::EOF }
        tokens.last.line.should eq 2
      end

      it "accepts a filename from IO constructor" do
        io = IO::Memory.new("42")
        lex = Lexer.new(io, "test.rb")
        lex.next_token.kind.should eq TokenKind::Integer
      end
    end
  end
end
