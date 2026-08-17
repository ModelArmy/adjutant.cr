require "../../spec_helper"

module Adjutant
  # Regexp: /pattern/flags literal syntax (Op::MakeRegex in vm.cr,
  # compiled via compile_regex in compiler.cr) plus Regexp.new,
  # backed by RegexpObject (builtins/regexp.cr) — a RubyObject
  # subclass holding the real compiled Crystal ::Regex, since there's
  # no Value variant for it. MatchData (also builtins/regexp.cr) is
  # MatchDataObject, produced by Regexp#match.
  #
  # $~/$1.. globals are NOT covered here. Nor is `#=~` — it's not
  # defined at all (see the comment above its would-be definition
  # site in regexp.cr): no infix `=~` support and no working dot-call
  # spelling either, so a native method there would be unreachable
  # from any script syntax. `#===` IS covered, but only via `.===(x)`
  # dot-call and `case/when` — bare infix `a === b` doesn't parse in
  # Adjutant either (see UNSUPPORTED.md's U017). Nor is
  # String#gsub/#sub/#index/#rindex/#split accepting a Regexp pattern
  # — String's own pattern-taking methods still only accept String
  # (see string_pattern_arg in string.cr); that integration is a
  # separate, later piece of work.
  describe "Regexp" do
    it "a literal's class is Regexp" do
      eval("/abc/.class == Regexp").truthy?.should be_true
    end

    it "a literal is_a?(Regexp)" do
      eval("/abc/.is_a?(Regexp)").truthy?.should be_true
    end

    it "is a real RubyObject, not a String" do
      eval("/abc/.is_a?(String)").falsy?.should be_true
    end

    describe "#source / #options / #casefold?" do
      it "source returns the pattern text" do
        eval("/abc/.source").as_string.should eq "abc"
      end

      it "options is 0 with no flags" do
        eval("/abc/.options").as_int.should eq 0
      end

      it "options reflects IGNORECASE" do
        eval("/abc/i.options == Regexp::IGNORECASE").truthy?.should be_true
      end

      it "options combines multiple flags with |" do
        result = eval("/abc/im.options == (Regexp::IGNORECASE | Regexp::MULTILINE)")
        result.truthy?.should be_true
      end

      it "casefold? is true only when /i was given" do
        eval("/abc/i.casefold?").truthy?.should be_true
        eval("/abc/.casefold?").falsy?.should be_true
      end
    end

    # Before this, Regexp had no to_s/inspect at all — it fell
    # through to Object's own default #inspect, listing ivars
    # (#<Regexp @__source="abc", @__options=0>), leaking internal
    # names, not real Ruby's actual formats.
    describe "#to_s" do
      it "no flags: shows every letter as disabled, no enabled letters before the dash" do
        eval("/abc/.to_s").as_string.should eq "(?-mix:abc)"
      end

      it "a single flag: shown before the dash, remaining two after, in m,i,x order" do
        eval("/abc/i.to_s").as_string.should eq "(?i-mx:abc)"
      end

      it "multiple flags: still m,i,x order, only the ones actually set appear before the dash" do
        eval("/abc/mi.to_s").as_string.should eq "(?mi-x:abc)"
      end

      it "every flag enabled: the -disabled section is omitted entirely, no trailing dash" do
        eval("/abc/mix.to_s").as_string.should eq "(?mix:abc)"
      end
    end

    describe "#inspect" do
      it "no flags: plain /pattern/, no trailing flag letters at all" do
        eval("/abc/.inspect").as_string.should eq "/abc/"
      end

      it "a single flag appended directly after the closing slash" do
        eval("/abc/i.inspect").as_string.should eq "/abc/i"
      end

      it "multiple flags: m,i,x order, matching to_s's own enabled-side order" do
        eval("/abc/mix.inspect").as_string.should eq "/abc/mix"
      end
    end

    describe "interpolation" do
      it "builds the pattern from an interpolated expression" do
        result = eval(<<-RUBY)
          x = "b"
          /a\#{x}c/.source
        RUBY
        result.as_string.should eq "abc"
      end

      it "an interpolated literal still matches correctly" do
        result = eval(<<-RUBY)
          x = "b"
          /a\#{x}c/.match?("abc")
        RUBY
        result.truthy?.should be_true
      end
    end

    describe "Regexp.new" do
      it "constructs a Regexp equivalent to literal syntax" do
        eval(%(Regexp.new("abc").source == /abc/.source)).truthy?.should be_true
      end

      it "accepts an options bitmask as the second argument" do
        result = eval("Regexp.new(\"abc\", Regexp::IGNORECASE).casefold?")
        result.truthy?.should be_true
      end

      it "given an existing Regexp, copies its source and options" do
        result = eval(<<-RUBY)
          r1 = /abc/i
          r2 = Regexp.new(r1)
          [r2.source, r2.options == r1.options]
        RUBY
        arr = result.as_array
        arr[0].as_string.should eq "abc"
        arr[1].as_bool.should be_true
      end
    end

    describe "^ and $ always match line boundaries (real Ruby semantics)" do
      # The single most important compatibility gotcha from this
      # phase's own planning: Ruby's ^/$ are NOT gated by
      # Regexp::MULTILINE the way PCRE2's are by default — they
      # always match line boundaries. Builtins.regex_options passes
      # Regex::Options::MULTILINE unconditionally to reproduce this;
      # this spec is here specifically to catch a regression if that
      # mapping is ever "simplified" back to the naive (wrong) 1:1
      # flag translation.
      it "^ matches the start of a later line without the /m flag" do
        result = eval(<<-RUBY)
          text = "foo\\nbar"
          /^bar/.match?(text)
        RUBY
        result.truthy?.should be_true
      end

      it "$ matches the end of an earlier line without the /m flag" do
        result = eval(<<-RUBY)
          text = "foo\\nbar"
          /foo$/.match?(text)
        RUBY
        result.truthy?.should be_true
      end
    end

    describe "#match / #match?" do
      it "match returns a MatchData on success" do
        eval(%(/b./.match("abc").class == MatchData)).truthy?.should be_true
      end

      it "match returns nil on no match" do
        eval(%(/xyz/.match("abc"))).null?.should be_true
      end

      it "match? returns a plain boolean, true on match" do
        eval(%(/b./.match?("abc"))).as_bool.should be_true
      end

      it "match? returns false on no match" do
        eval(%(/xyz/.match?("abc"))).as_bool.should be_false
      end

      it "raises R022 (ArgumentError) when no string argument is given" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("/abc/.match") }
        error.diagnostic.not_nil!.code.should eq("R022")
      end

      it "the ArgumentError is rescuable from script" do
        result = eval(<<-RUBY)
          begin
            /abc/.match
            false
          rescue ArgumentError
            true
          end
        RUBY
        result.as_bool.should be_true
      end

      it "with a block, yields the MatchData (not just the substring)" do
        result = eval(%(/b./.match("abc") { |md| md[0] }))
        result.as_string.should eq "bc"
      end

      it "with a block, returns the block's own return value" do
        result = eval(%(/b./.match("abc") { |md| md.begin(0) }))
        result.as_int.should eq 1
      end

      it "with a block, is not invoked at all on no match" do
        result = eval(%(/xyz/.match("abc") { |md| "should not run" }))
        result.null?.should be_true
      end

      it "with a block, break escapes with the break value" do
        result = eval(%(/l+/.match("hello") { break :broke }))
        result.as_sym.name.should eq "broke"
      end
    end

    describe "#===" do
      # No infix `a === b` support in Adjutant at all (see
      # UNSUPPORTED.md's U017 — TripleEq is a real token wherever
      # `===` appears, but it's deliberately absent from the
      # PRECEDENCE table). `.===(x)` DOES work, though — parse_postfix's
      # dot-call handling accepts any token's lexeme as the method
      # name, TripleEq included, so this reaches the same native
      # method case/when itself dispatches to. Both are covered here.
      it "true on match, called directly via dot syntax" do
        eval(%(/^b/.===("bar"))).truthy?.should be_true
      end

      it "false on no match" do
        eval(%(/^z/.===("bar"))).falsy?.should be_true
      end

      it "false (not a raised error) for a non-String right-hand side" do
        eval(%(/abc/.===(5))).falsy?.should be_true
      end

      it "drives a case/when statement" do
        result = eval(<<-RUBY)
          case "hello"
          when /^h/
            "matched"
          else
            "no match"
          end
        RUBY
        result.as_string.should eq "matched"
      end
    end

    it "an invalid pattern raises R021 (RegexpError)" do
      interp, _ = make_interp
      error = expect_raises(RuntimeError) { interp.eval("/(abc/") }
      error.diagnostic.not_nil!.code.should eq("R021")
    end

    it "the RegexpError is rescuable from script" do
      # A malformed pattern can't appear as a literal inside a
      # begin/rescue the way other runtime errors can (a regex
      # LITERAL is evaluated the instant its bytecode runs, before
      # any rescue clause could wrap it) — covered instead via
      # Regexp.new, which raises the same R021/RegexpError from
      # Builtins.compile_regex, at a point script code CAN wrap in
      # begin/rescue.
      result = eval(<<-RUBY)
        begin
          Regexp.new("(abc")
          false
        rescue RegexpError
          true
        end
      RUBY
      result.as_bool.should be_true
    end

    it "every builtin Regexp method defaults to RiskProfile.none" do
      interp, _ = make_interp
      cls = interp.get_global("Regexp").as_rclass
      %w[source options casefold? match match? ===].each do |name|
        sym_id = interp.symbols.lookup(name).not_nil!.value
        cls.find_native_method(sym_id).not_nil!.risk.should eq RiskProfile.none
      end
    end
  end

  describe "MatchData" do
    it "[] returns the whole match at index 0" do
      eval(%(/b./.match("abc")[0])).as_string.should eq "bc"
    end

    it "[] returns a capture group by index" do
      eval(%(/a(b)(c)/.match("abc")[1])).as_string.should eq "b"
      eval(%(/a(b)(c)/.match("abc")[2])).as_string.should eq "c"
    end

    it "[] returns a named capture by name" do
      result = eval(%(/a(?<mid>b)c/.match("abc")["mid"]))
      result.as_string.should eq "b"
    end

    it "[] returns nil for a group that didn't participate" do
      result = eval(%(/a(b)|a(c)/.match("ac")[1]))
      result.null?.should be_true
    end

    it "to_s returns the whole matched substring" do
      eval(%(/b./.match("abc").to_s)).as_string.should eq "bc"
    end

    it "pre_match / post_match return the text around the match" do
      result = eval(<<-RUBY)
        md = /b./.match("xxbcyy")
        [md.pre_match, md.post_match]
      RUBY
      arr = result.as_array
      arr[0].as_string.should eq "xx"
      arr[1].as_string.should eq "yy"
    end

    it "string returns the original subject" do
      result = eval(<<-RUBY)
        s = "xxbcyy"
        /b./.match(s).string == s
      RUBY
      result.truthy?.should be_true
    end

    it "begin returns the match's start offset" do
      eval(%(/b./.match("xxbcyy").begin)).as_int.should eq 2
    end

    it "begin(n) returns a capture group's start offset" do
      eval(%(/a(b)/.match("xab").begin(1))).as_int.should eq 2
    end
  end
end
