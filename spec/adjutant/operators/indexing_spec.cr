require "../../spec_helper"

module Adjutant
  # Runs `src` as a method body and returns its result's `inspect`, or
  # the class of the error it raised.
  private def self.index_outcome(src : String) : String
    eval(<<-RUBY).as_string
      def run_index_case
        #{src}
      end
      begin
        run_index_case.inspect
      rescue NoMethodError
        "NoMethodError"
      rescue TypeError
        "TypeError"
      rescue IndexError
        "IndexError"
      rescue FrozenError
        "FrozenError"
      end
      RUBY
  end

  describe "indexing" do
    describe "an Array" do
      it "slices by Range, with or without bounds" do
        a = "a = [1, 2, 3, 4, 5]\n"
        index_outcome(a + "a[1..2]").should eq "[2, 3]"
        index_outcome(a + "a[1..]").should eq "[2, 3, 4, 5]"
        index_outcome(a + "a[..-2]").should eq "[1, 2, 3, 4]"
        index_outcome(a + "a[1...-1]").should eq "[2, 3, 4]"
        index_outcome(a + "a[3..1]").should eq "[]"
      end

      it "gives [] at the end and nil past it" do
        a = "a = [1, 2, 3, 4, 5]\n"
        index_outcome(a + "a[5..]").should eq "[]"
        index_outcome(a + "a[6..]").should eq "nil"
        index_outcome(a + "a[5, 1]").should eq "[]"
        index_outcome(a + "a[6, 1]").should eq "nil"
      end

      it "slices by start and length" do
        a = "a = [1, 2, 3, 4, 5]\n"
        index_outcome(a + "a[1, 2]").should eq "[2, 3]"
        index_outcome(a + "a[-2, 5]").should eq "[4, 5]"
        index_outcome(a + "a[1, -1]").should eq "nil"
      end

      it "truncates a Float index and raises TypeError for a non-number" do
        a = "a = [1, 2, 3]\n"
        index_outcome(a + "a[1.5]").should eq "2"
        index_outcome(a + %(a["a"])).should eq "TypeError"
        index_outcome(a + "a[nil]").should eq "TypeError"
      end
    end

    describe "a String" do
      it "slices by Range, with or without bounds, and by start and length" do
        s = %(s = "hello"\n)
        index_outcome(s + "s[1..]").should eq %("ello")
        index_outcome(s + "s[..2]").should eq %("hel")
        index_outcome(s + "s[1, 3]").should eq %("ell")
        index_outcome(s + "s[5, 1]").should eq %("")
        index_outcome(s + "s[6, 1]").should eq "nil"
      end

      it "finds a String or Regexp, or a Regexp's capture" do
        s = %(s = "hello"\n)
        index_outcome(s + %(s["ll"])).should eq %("ll")
        index_outcome(s + %(s["z"])).should eq "nil"
        index_outcome(s + "s[/l+/]").should eq %("ll")
        index_outcome(s + "s[/z/]").should eq "nil"
        index_outcome(s + "s[/(h)(e)/, 2]").should eq %("e")
      end
    end

    describe "other receivers" do
      it "reads an Integer's bits" do
        index_outcome("5[0]").should eq "1"
        index_outcome("6[0]").should eq "0"
        index_outcome("5[2]").should eq "1"
      end

      it "slices a Symbol's name" do
        index_outcome(":abc[0]").should eq %("a")
        index_outcome(":abc[1..]").should eq %("bc")
      end

      it "calls a lambda" do
        index_outcome("l = ->(x) { x * 2 }\nl[3]").should eq "6"
      end

      it "raises NoMethodError without a `[]`" do
        index_outcome("nil[0]").should eq "NoMethodError"
        index_outcome("Object.new[0]").should eq "NoMethodError"
      end
    end
  end

  describe "index assignment" do
    describe "an Array" do
      it "pads with nil past the end" do
        index_outcome("a = [1, 2]\na[4] = 9\na").should eq "[1, 2, nil, nil, 9]"
        index_outcome("a = [1, 2]\na[4..] = [9]\na").should eq "[1, 2, nil, nil, 9]"
      end

      it "raises IndexError before the start" do
        index_outcome("a = [1, 2]\na[-9] = 1").should eq "IndexError"
      end

      it "replaces a Range or start and length with the elements given" do
        index_outcome("a = [1, 2, 3, 4]\na[1..2] = [:x]\na").should eq "[1, :x, 4]"
        index_outcome("a = [1, 2, 3, 4]\na[1, 2] = [:x, :y, :z]\na").should eq "[1, :x, :y, :z, 4]"
        index_outcome("a = [1, 2, 3, 4]\na[1..2] = 9\na").should eq "[1, 9, 4]"
        index_outcome("a = [1, 2]\na[1, 0] = [:x]\na").should eq "[1, :x, 2]"
      end

      it "returns the assigned value" do
        index_outcome("a = [1]\na[0] = 5").should eq "5"
      end
    end

    it "raises FrozenError for a String, as under frozen_string_literal" do
      index_outcome(%(s = "abc"\ns[0] = "x")).should eq "FrozenError"
      eval(%(s = "abc"\nbegin\n  s[0] = "x"\nrescue FrozenError => e\n  e.message\nend)).as_string
        .should eq %(can't modify frozen String: "abc")
    end

    it "raises NoMethodError without a `[]=`" do
      index_outcome("nil[0] = 1").should eq "NoMethodError"
      index_outcome("5[0] = 1").should eq "NoMethodError"
    end
  end
end
