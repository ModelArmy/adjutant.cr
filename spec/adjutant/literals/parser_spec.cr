require "../../spec_helper"

module Adjutant
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

      describe "string escape sequences" do
        # Found 2026-08-13 while adding String#chomp/#gsub/etc: NOTHING
        # in the parser/compiler pipeline decoded these before —
        # `strip_quotes` only removed the surrounding quotes, and
        # every double-quoted string containing `\n`/`\t`/etc. silently
        # held the literal 2-character sequence instead of the
        # intended control character. See decode_string_escapes'
        # own comment (parser.cr) for the full story.
        it "decodes \\n as a newline" do
          node = parse_expr(%("a\\nb"))
          node.as(StringLiteral).value.should eq "a\nb"
        end

        it "decodes \\t as a tab" do
          node = parse_expr(%("a\\tb"))
          node.as(StringLiteral).value.should eq "a\tb"
        end

        it "decodes \\\\ as a literal backslash" do
          node = parse_expr(%("a\\\\b"))
          node.as(StringLiteral).value.should eq "a\\b"
        end

        it "decodes \\\" inside a double-quoted string" do
          node = parse_expr(%("a\\"b"))
          node.as(StringLiteral).value.should eq "a\"b"
        end

        it "decodes \\xHH hex escapes" do
          node = parse_expr(%("\\x41"))
          node.as(StringLiteral).value.should eq "A"
        end

        it "decodes \\uHHHH unicode escapes" do
          node = parse_expr(%("\\u0041"))
          node.as(StringLiteral).value.should eq "A"
        end

        it "decodes \\u{H...} unicode escapes" do
          node = parse_expr(%("\\u{41}"))
          node.as(StringLiteral).value.should eq "A"
        end

        it "drops the backslash for an unrecognized escape, keeping the character" do
          node = parse_expr(%("\\d"))
          node.as(StringLiteral).value.should eq "d"
        end

        it "single-quoted strings do NOT decode \\n — it stays two literal characters" do
          node = parse_expr(%('a\\nb'))
          node.as(StringLiteral).value.should eq "a\\nb"
        end

        it "single-quoted strings decode \\\\ as a literal backslash" do
          node = parse_expr(%('a\\\\b'))
          node.as(StringLiteral).value.should eq "a\\b"
        end

        it "single-quoted strings decode \\' as a literal quote" do
          node = parse_expr("'a\\'b'")
          node.as(StringLiteral).value.should eq "a'b"
        end

        it "decodes escapes inside interpolated-string fragments too" do
          node = parse_expr(%("a\\n\#{1}b\\t"))
          node.should be_a(InterpString)
          parts = node.as(InterpString).parts
          parts.first.should be_a(StringFragment)
          parts.first.as(StringFragment).value.should eq "a\n"
          parts.last.should be_a(StringFragment)
          parts.last.as(StringFragment).value.should eq "b\t"
        end
      end

      describe "regex literals" do
        it "parses a simple regex literal" do
          node = parse_expr("/abc/")
          node.should be_a(RegexLiteral)
          regex = node.as(RegexLiteral)
          regex.parts.size.should eq 1
          regex.parts.first.should be_a(RegexFragment)
          regex.parts.first.as(RegexFragment).value.should eq "abc"
          regex.flags.should eq ""
        end

        it "carries the flag letters" do
          node = parse_expr("/abc/im")
          node.as(RegexLiteral).flags.should eq "im"
        end

        it "does NOT decode escapes in the pattern, unlike a string literal" do
          node = parse_expr("/a\\nb/")
          node.as(RegexLiteral).parts.first.as(RegexFragment).value.should eq "a\\nb"
        end

        it "parses an interpolated regex into alternating fragment/expression parts" do
          node = parse_expr(%(/hello \#{name}!/i))
          node.should be_a(RegexLiteral)
          regex = node.as(RegexLiteral)
          regex.parts[0].should be_a(RegexFragment)
          regex.parts[0].as(RegexFragment).value.should eq "hello "
          regex.parts[1].should be_a(Identifier)
          regex.parts[1].as(Identifier).name.should eq "name"
          regex.parts[2].should be_a(RegexFragment)
          regex.parts[2].as(RegexFragment).value.should eq "!"
          regex.flags.should eq "i"
        end
      end

      describe "global variables (U011 — deliberately unsupported)" do
        it "raises U011 by name rather than the generic P002 fallback" do
          error = expect_raises(ParseError) { parse_expr("$foo") }
          diag = error.diagnostic.not_nil!
          diag.code.should eq("U011")
          diag.data["name"].should eq("$foo")
        end

        it "rejects Regexp's own would-be match globals the same way" do
          # The specific case this check was added for: deciding
          # against building real Ruby's $~/$1-$9 match globals for
          # Regexp (see UNSUPPORTED.md's U011 entry) means these need
          # to fail clearly, not silently misparse.
          %w[$~ $1 $9 $& $` $' $+].each do |name|
            error = expect_raises(ParseError) { parse_expr(name) }
            error.diagnostic.not_nil!.code.should eq("U011")
          end
        end

        it "rejects a global as an assignment target too, not just a read" do
          error = expect_raises(ParseError) { parse_expr("$foo = 1") }
          error.diagnostic.not_nil!.code.should eq("U011")
        end
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

      describe "%w[] / %i[] literals" do
        it "parses %w[] as an ArrayLiteral of StringLiteral" do
          node = parse_expr("%w[a b c]").as(ArrayLiteral)
          node.elements.size.should eq 3
          node.elements.map { |e| e.as(StringLiteral).value }.should eq ["a", "b", "c"]
        end

        it "parses %i[] as an ArrayLiteral of SymbolLiteral" do
          node = parse_expr("%i[a b c]").as(ArrayLiteral)
          node.elements.size.should eq 3
          node.elements.map { |e| e.as(SymbolLiteral).value }.should eq ["a", "b", "c"]
        end

        it "parses an empty %w[] as an empty ArrayLiteral" do
          parse_expr("%w[]").as(ArrayLiteral).elements.should be_empty
        end
      end

      describe "heredocs" do
        it "parses a plain <<ID heredoc as a StringLiteral" do
          node = parse_expr("<<HERE\nhello\nHERE\n")
          node.should be_a(StringLiteral)
          node.as(StringLiteral).value.should eq "hello\n"
        end

        it "parses an interpolating heredoc as an InterpString" do
          node = parse_expr("<<HERE\nx=\#{y}\nHERE\n")
          node.should be_a(InterpString)
        end

        it "parses a single-quoted heredoc as a literal StringLiteral, \#{} uninterpreted" do
          node = parse_expr("<<'HERE'\nx=\#{y}\nHERE\n")
          node.should be_a(StringLiteral)
          node.as(StringLiteral).value.should eq "x=\#{y}\n"
        end

        it "dedents a squiggly <<~ID heredoc to its least-indented line" do
          node = parse_expr("x = <<~HERE\n    first\n      second\n    HERE\n")
          # `x = ...` makes this an assignment; unwrap to the RHS
          node.should be_a(Assign)
          rhs = node.as(Assign).value
          rhs.should be_a(StringLiteral)
          rhs.as(StringLiteral).value.should eq "first\n  second\n"
        end
      end

      it "parses a hash literal" do
        node = parse_expr(%({ "a" => 1 }))
        node.should be_a(HashLiteral)
        node.as(HashLiteral).pairs.size.should eq 1
      end

      it "parses symbol-shorthand hash literal syntax ({k: v})" do
        node = parse_expr("{ a: 1, b: 2 }").as(HashLiteral)
        node.pairs.size.should eq 2
        key0, val0 = node.pairs[0]
        key0.should be_a(SymbolLiteral)
        key0.as(SymbolLiteral).value.should eq "a"
        val0.should be_a(IntLiteral)
        key1, _ = node.pairs[1]
        key1.as(SymbolLiteral).value.should eq "b"
      end

      it "allows a reserved word as a symbol-shorthand label, same as " \
         "real Ruby (`class:`, not just ordinary identifiers)" do
        node = parse_expr("{ class: Foo }").as(HashLiteral)
        key, _ = node.pairs[0]
        key.as(SymbolLiteral).value.should eq "class"
      end

      it "mixes symbol-shorthand and hash-rocket entries in one literal" do
        node = parse_expr(%({ a: 1, "b" => 2 })).as(HashLiteral)
        node.pairs.size.should eq 2
        node.pairs[0][0].as(SymbolLiteral).value.should eq "a"
        node.pairs[1][0].should be_a(StringLiteral)
      end

      it "does not treat `key :` (with a space before the colon) as " \
         "shorthand — requires the colon to hug the label, same as real " \
         "Ruby's own label-token rule" do
        # Falls through to the ordinary expression+hash-rocket path,
        # so a bare `a` with no `=>` following is simply a parse
        # error here, not a symbol-shorthand match — confirms the
        # space-before check is actually gating something, rather
        # than this test accidentally passing for an unrelated reason.
        expect_raises(ParseError) do
          parse_expr("{ a : 1 }")
        end
      end

      it "a ternary inside a hash value is not mistaken for label syntax " \
         "(the label check only fires on the KEY position, so a bare `?` " \
         "immediately after a would-be label never gets this far)" do
        node = parse_expr("{ a: cond ? 1 : 2 }").as(HashLiteral)
        key, val = node.pairs[0]
        key.as(SymbolLiteral).value.should eq "a"
        val.should be_a(Ternary)
      end

      it "a ternary as a hash-rocket KEY still parses correctly — the " \
         "label check requires an immediately-hugging colon, which a " \
         "spaced-out ternary `?  :` never produces at key position" do
        node = parse_expr(%({ (cond ? "x" : "y") => 1 })).as(HashLiteral)
        key, _ = node.pairs[0]
        key.should be_a(Ternary)
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

      # Endless/beginless ranges — see SCOPE.md's now-resolved Must
      # Fix entry for the full research trail. `start_node`/`end_node`
      # are nilable specifically to represent these; every OTHER
      # RangeLiteral consumer (compile_range) must handle a nil bound
      # too, but that's covered by builtins/range_spec.cr and the
      # mruby range fixture, not here — this file is parser-shape only.

      it "parses an inclusive endless range" do
        node = parse_expr("1..").as(RangeLiteral)
        node.start_node.should be_a(IntLiteral)
        node.end_node.should be_nil
        node.exclusive?.should be_false
      end

      it "parses an exclusive endless range" do
        node = parse_expr("1...").as(RangeLiteral)
        node.start_node.should be_a(IntLiteral)
        node.end_node.should be_nil
        node.exclusive?.should be_true
      end

      it "parses an inclusive beginless range" do
        node = parse_expr("..10").as(RangeLiteral)
        node.start_node.should be_nil
        node.end_node.should be_a(IntLiteral)
        node.exclusive?.should be_false
      end

      it "parses an exclusive beginless range" do
        node = parse_expr("...10").as(RangeLiteral)
        node.start_node.should be_nil
        node.end_node.should be_a(IntLiteral)
        node.exclusive?.should be_true
      end

      it "parses an endless range as an array index (arr[2..])" do
        node = parse("arr = []\narr[2..]").stmts.last
        node.should be_a(Index)
        idx = node.as(Index).index.as(RangeLiteral)
        idx.start_node.should be_a(IntLiteral)
        idx.end_node.should be_nil
      end

      it "parses an endless range followed by a comma, in an array literal" do
        node = parse_expr("[2.., 3]").as(ArrayLiteral)
        first = node.elements.first.as(RangeLiteral)
        first.start_node.should be_a(IntLiteral)
        first.end_node.should be_nil
        node.elements[1].should be_a(IntLiteral)
      end

      it "parses an endless range as a case/when pattern, followed by then" do
        node = parse_expr("case 20\nwhen 18.. then :adult\nend").as(CaseNode)
        pattern = node.whens.first[0].first.as(RangeLiteral)
        pattern.start_node.should be_a(IntLiteral)
        pattern.end_node.should be_nil
      end

      it "parses an endless range as a call argument (in parens)" do
        node = parse_expr("f(2..)")
        node.should be_a(Call)
        arg = node.as(Call).args.first.as(RangeLiteral)
        arg.start_node.should be_a(IntLiteral)
        arg.end_node.should be_nil
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
  end
end
