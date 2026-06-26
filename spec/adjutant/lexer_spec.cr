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
    end

    describe "float literals" do
      it "scans a float" do
        pairs("3.14").should eq [{TokenKind::Float, "3.14"}]
      end

      it "does not treat 3.. as float" do
        kinds("3..").should eq [TokenKind::Integer, TokenKind::RangeIncl]
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
