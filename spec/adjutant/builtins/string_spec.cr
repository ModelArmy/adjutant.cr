require "../../spec_helper"

module Adjutant
  # Covers Phase 4a of the base-types work: String. `+`, `==`,
  # `<`/`<=`/`>`/`>=`, and `[]` are already opcodes (see ValueOps.add/
  # equal?/compare and exec_get_index in vm.cr) and covered
  # elsewhere; this file covers String's own RubyClass (.class,
  # is_a?, superclass) and its native methods.
  describe "String" do
    it "\"x\".class is String" do
      interp, _ = make_interp
      result = interp.eval(%("x".class == String))
      result.truthy?.should be_true
    end

    it "\"x\".is_a?(String) is true" do
      interp, _ = make_interp
      result = interp.eval(%("x".is_a?(String)))
      result.truthy?.should be_true
    end

    it "String.superclass is Object" do
      interp, _ = make_interp
      result = interp.eval("String.superclass == Object")
      result.truthy?.should be_true
    end

    it "String.class is Class" do
      interp, _ = make_interp
      result = interp.eval("String.class == Class")
      result.truthy?.should be_true
    end

    describe "#to_s" do
      it "is identity" do
        interp, _ = make_interp
        result = interp.eval(%("hello".to_s))
        result.as_string.should eq "hello"
      end
    end

    describe "#to_i" do
      it "parses a numeric string" do
        interp, _ = make_interp
        result = interp.eval(%("42".to_i))
        result.as_int.should eq 42
      end

      it "returns 0 for a non-numeric string, not an error" do
        interp, _ = make_interp
        result = interp.eval(%("abc".to_i))
        result.as_int.should eq 0
      end
    end

    describe "#to_f" do
      it "parses a decimal string" do
        interp, _ = make_interp
        result = interp.eval(%("3.5".to_f))
        result.as_float.should eq 3.5
      end
    end

    describe "#to_sym" do
      it "produces a real symbol comparable via == to a literal" do
        interp, _ = make_interp
        result = interp.eval(%("foo".to_sym == :foo))
        result.truthy?.should be_true
      end
    end

    describe "#length / #size" do
      it "both return the character count" do
        interp, _ = make_interp
        result = interp.eval(%(["hello".length, "hello".size]))
        result.as_array.map(&.as_int).should eq [5, 5]
      end

      it "now resolves via String's own native method, not just the generic fallback" do
        interp, _ = make_interp
        result = interp.eval(%("hi".respond_to?(:length)))
        result.truthy?.should be_true
      end
    end

    describe "#upcase / #downcase" do
      it "upcase converts to uppercase" do
        interp, _ = make_interp
        result = interp.eval(%("Hello".upcase))
        result.as_string.should eq "HELLO"
      end

      it "downcase converts to lowercase" do
        interp, _ = make_interp
        result = interp.eval(%("Hello".downcase))
        result.as_string.should eq "hello"
      end
    end

    describe "#strip" do
      it "removes leading and trailing whitespace" do
        interp, _ = make_interp
        result = interp.eval(%("  hi  ".strip))
        result.as_string.should eq "hi"
      end
    end

    describe "#empty?" do
      it "true for an empty string" do
        interp, _ = make_interp
        result = interp.eval(%("".empty?))
        result.truthy?.should be_true
      end

      it "false for a non-empty string" do
        interp, _ = make_interp
        result = interp.eval(%("x".empty?))
        result.falsy?.should be_true
      end
    end

    describe "#include?" do
      it "true when the substring is present" do
        interp, _ = make_interp
        result = interp.eval(%("hello world".include?("world")))
        result.truthy?.should be_true
      end

      it "false when the substring is absent" do
        interp, _ = make_interp
        result = interp.eval(%("hello world".include?("bye")))
        result.falsy?.should be_true
      end
    end

    describe "#split" do
      it "splits on whitespace with no argument, collapsing runs" do
        interp, _ = make_interp
        result = interp.eval(%("a  b c".split))
        result.as_array.map(&.as_string).should eq ["a", "b", "c"]
      end

      it "splits on a given separator string" do
        interp, _ = make_interp
        result = interp.eval(%("a,b,c".split(",")))
        result.as_array.map(&.as_string).should eq ["a", "b", "c"]
      end

      it "returns a real Array Value usable with existing indexing/length" do
        interp, _ = make_interp
        result = interp.eval(%("a,b,c".split(",").length))
        result.as_int.should eq 3
      end
    end

    describe "opcodes already handle String correctly (regression check, not new behavior)" do
      it "+ concatenates" do
        interp, _ = make_interp
        result = interp.eval(%("foo" + "bar"))
        result.as_string.should eq "foobar"
      end

      it "== compares by value" do
        interp, _ = make_interp
        result = interp.eval(%("abc" == "abc"))
        result.truthy?.should be_true
      end

      it "< compares lexicographically" do
        interp, _ = make_interp
        result = interp.eval(%("abc" < "abd"))
        result.truthy?.should be_true
      end

      it "[] indexes a single character" do
        interp, _ = make_interp
        result = interp.eval(%("hello"[1]))
        result.as_string.should eq "e"
      end

      describe "[] with a Range" do
        it "returns a substring for an inclusive range" do
          eval(%("hello"[1..3])).as_string.should eq "ell"
        end

        it "returns a substring for an exclusive range" do
          eval(%("hello"[1...3])).as_string.should eq "el"
        end

        it "supports negative bounds, counting from the end" do
          eval(%("hello"[1..-2])).as_string.should eq "ell"
        end

        it "clamps an end beyond the string's length" do
          eval(%("hello"[1..100])).as_string.should eq "ello"
        end

        it "returns an empty string when the start is exactly at the length" do
          eval(%("abc"[3..5])).as_string.should eq ""
        end

        it "returns nil when the start is beyond the length" do
          eval(%("abc"[10..20])).null?.should be_true
        end

        it "returns nil when a negative start is still out of range after adjustment" do
          eval(%("abc"[-10..2])).null?.should be_true
        end
      end
    end

    describe "#reverse" do
      it "reverses the characters" do
        eval(%("hello".reverse)).as_string.should eq "olleh"
      end
    end

    describe "#chars" do
      it "returns an Array of single-character strings" do
        interp, _ = make_interp
        result = interp.eval(%("abc".chars))
        result.as_array.map(&.as_string).should eq ["a", "b", "c"]
      end

      it "on an empty string returns an empty array" do
        interp, _ = make_interp
        result = interp.eval(%("".chars))
        result.as_array.empty?.should be_true
      end
    end

    describe "#start_with? / #end_with?" do
      it "start_with? is true for a matching prefix" do
        eval(%("hello".start_with?("he"))).as_bool.should be_true
      end

      it "start_with? is false for a non-matching prefix" do
        eval(%("hello".start_with?("lo"))).as_bool.should be_false
      end

      it "end_with? is true for a matching suffix" do
        eval(%("hello".end_with?("lo"))).as_bool.should be_true
      end

      it "end_with? is false for a non-matching suffix" do
        eval(%("hello".end_with?("he"))).as_bool.should be_false
      end
    end

    describe "#capitalize" do
      it "upcases the first character and downcases the rest" do
        eval(%("heLLO wORLD".capitalize)).as_string.should eq "Hello world"
      end

      it "on an already-capitalized string is a no-op" do
        eval(%("Hello".capitalize)).as_string.should eq "Hello"
      end
    end

    describe "label propagation on scalar-to-scalar/container transforms" do
      # upcase/downcase/strip/reverse/capitalize/chars/to_i/to_f/to_sym
      # previously dropped the receiver's own label entirely — fixed
      # alongside this session's other work (same category of gap
      # already fixed for Array#push/#map).
      it "reverse carries the receiver's label forward" do
        interp, _ = make_interp
        interp.define_native("tainted_string") do |args|
          Value.string("hello", RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High))
        end
        result = interp.eval("tainted_string.reverse")
        result.label.should_not be_nil
      end

      it "upcase carries the receiver's label forward" do
        interp, _ = make_interp
        interp.define_native("tainted_string") do |args|
          Value.string("hello", RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High))
        end
        result = interp.eval("tainted_string.upcase")
        result.label.should_not be_nil
      end

      it "chars carries the receiver's label forward onto the resulting array" do
        interp, _ = make_interp
        interp.define_native("tainted_string") do |args|
          Value.string("ab", RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High))
        end
        result = interp.eval("tainted_string.chars")
        result.label.should_not be_nil
      end
    end

    describe "#chomp" do
      it "strips a single trailing newline" do
        eval(%("abc\\n".chomp)).as_string.should eq "abc"
      end

      it "strips a single trailing \\r\\n as one unit" do
        eval(%("abc\\r\\n".chomp)).as_string.should eq "abc"
      end

      it "leaves a string with no trailing newline unchanged" do
        eval(%("abc".chomp)).as_string.should eq "abc"
      end

      it "only strips one trailing newline by default, not a whole run" do
        eval(%("abc\\n\\n".chomp)).as_string.should eq "abc\n"
      end

      it "with an explicit non-empty separator, strips that exact suffix" do
        eval(%("abc\\t".chomp("\\t"))).as_string.should eq "abc"
      end

      it "with an explicit empty separator, strips every trailing newline" do
        eval(%("abc\\n\\n\\n".chomp(""))).as_string.should eq "abc"
      end

      it "with a non-matching separator, is a no-op" do
        eval(%("abc".chomp("xyz"))).as_string.should eq "abc"
      end
    end

    describe "#each_line" do
      it "yields each line WITH its trailing separator attached" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          lines = []
          "first line\\nsecond line\\nthird line".each_line { |l| lines << l }
          lines
        RUBY
        result.as_array.map(&.as_string).should eq ["first line\n", "second line\n", "third line"]
      end

      it "does not yield a trailing empty chunk when the string ends exactly on the separator" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          lines = []
          "a\\nb\\n".each_line { |l| lines << l }
          lines
        RUBY
        result.as_array.map(&.as_string).should eq ["a\n", "b\n"]
      end

      it "supports a custom separator" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          lines = []
          "aXbXc".each_line("X") { |l| lines << l }
          lines
        RUBY
        result.as_array.map(&.as_string).should eq ["aX", "bX", "c"]
      end

      it "returns the receiver" do
        interp, _ = make_interp
        result = interp.eval(%("a\\nb".each_line { |l| l } == "a\\nb"))
        result.truthy?.should be_true
      end

      it "with no block, does not raise, and returns the receiver" do
        interp, _ = make_interp
        result = interp.eval(%("a\\nb".each_line))
        result.as_string.should eq "a\nb"
      end
    end

    describe "#index" do
      it "finds the first occurrence" do
        eval(%("abcabc".index("a"))).as_int.should eq 0
      end

      it "returns nil when not found" do
        eval(%("abc".index("d"))).null?.should be_true
      end

      it "respects a start position" do
        eval(%("abcabc".index("a", 1))).as_int.should eq 3
      end

      it "supports a negative start position, counting from the end" do
        eval(%("hello".index("l", -2))).as_int.should eq 3
      end

      it "an empty pattern matches at the start position itself" do
        eval(%("hello".index("", 5))).as_int.should eq 5
      end

      it "a start position beyond the string's length returns nil, even for an empty pattern" do
        eval(%("hello".index("", 6))).null?.should be_true
      end

      it "raises ArgumentError with no pattern argument" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval(%("hello".index)) }
        error.diagnostic.not_nil!.code.should eq("R018")
      end

      it "raises TypeError for a non-String pattern" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval(%("hello".index(101))) }
        error.diagnostic.not_nil!.code.should eq("R019")
      end
    end

    describe "#rindex" do
      it "finds the last occurrence" do
        eval(%("abcabc".rindex("a"))).as_int.should eq 3
      end

      it "returns nil when not found" do
        eval(%("abc".rindex("d"))).null?.should be_true
      end

      it "respects a start position, searching backward from it" do
        eval(%("abcabc".rindex("a", 1))).as_int.should eq 0
      end

      it "supports a negative start position" do
        eval(%("abc".rindex("a", -4))).null?.should be_true
      end

      it "raises ArgumentError with no pattern argument" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval(%("hello".rindex)) }
        error.diagnostic.not_nil!.code.should eq("R018")
      end
    end

    describe "#gsub" do
      it "replaces every occurrence with a String replacement" do
        eval(%("abcabc".gsub("b", "B"))).as_string.should eq "aBcaBc"
      end

      it "replaces every occurrence via a block" do
        interp, _ = make_interp
        result = interp.eval(%("abcabc".gsub("b") { |w| w.upcase }))
        result.as_string.should eq "aBcaBc"
      end

      it "handles an empty pattern by inserting at every position, including start and end" do
        eval(%("hello".gsub("", "."))).as_string.should eq ".h.e.l.l.o."
      end

      it "does not mutate the receiver" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = "abc"
          a.gsub("b", "B")
          a
        RUBY
        result.as_string.should eq "abc"
      end

      describe "backslash references in a String replacement" do
        it "\\\\& / \\\\0 insert the matched text" do
          eval(%("a".gsub("a", "<\\\\&>"))).as_string.should eq "<a>"
        end

        it "\\\\` inserts everything before the match" do
          eval(%("abXcd".gsub("X", "<\\\\`>"))).as_string.should eq "ab<ab>cd"
        end

        it "\\\\' inserts everything after the match" do
          eval(%("abXcd".gsub("X", "<\\\\'>"))).as_string.should eq "ab<cd>cd"
        end

        it "\\\\\\\\ inserts a literal backslash" do
          eval(%("abXcd".gsub("X", "<\\\\\\\\>"))).as_string.should eq "ab<\\>cd"
        end
      end

      it "raises ArgumentError with neither a replacement nor a block" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval(%("abc".gsub("b"))) }
        error.diagnostic.not_nil!.code.should eq("R018")
      end
    end

    describe "#sub" do
      it "replaces only the FIRST occurrence" do
        eval(%("abcabc".sub("b", "B"))).as_string.should eq "aBcabc"
      end

      it "replaces only the first occurrence via a block" do
        interp, _ = make_interp
        result = interp.eval(%("abcabc".sub("b") { |w| w.upcase }))
        result.as_string.should eq "aBcabc"
      end

      it "with a pattern that isn't found, returns an equal but distinct string" do
        interp, _ = make_interp
        result = interp.eval(%("abc".sub("X", "Z")))
        result.as_string.should eq "abc"
      end
    end
  end
end
