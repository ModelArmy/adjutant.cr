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
    end
  end
end
