require "../../spec_helper"

module Adjutant
  # Runs `setup`, then returns `expr`'s `inspect`, or the class of the
  # error it raised.
  private def self.builtin_outcome(setup : String, expr : String) : String
    eval(<<-RUBY).as_string
      #{setup}
      begin
        (#{expr}).inspect
      rescue ZeroDivisionError
        "ZeroDivisionError"
      rescue IndexError
        "IndexError"
      rescue NoMethodError
        "NoMethodError"
      end
      RUBY
  end

  # The code of the RuntimeError `source` raises, or "no error".
  private def self.builtin_error_code(source : String) : String
    eval(source)
    "no error"
  rescue ex : RuntimeError
    ex.diagnostic.try(&.code) || "no code"
  end

  describe "Hash#each" do
    it "gives a single block parameter the [key, value] pair" do
      builtin_outcome("r = []\n{a: 1, b: 2}.each { |pair| r.push(pair) }", "r").should eq "[[:a, 1], [:b, 2]]"
    end

    it "still spreads the pair across two parameters" do
      builtin_outcome("r = []\n{a: 1}.each { |k, v| r.push(k, v) }", "r").should eq "[:a, 1]"
    end
  end

  describe "Float %" do
    it "gives NaN for a zero divisor when either side is a Float" do
      builtin_outcome("", "[(5.0 % 0).nan?, (5 % 0.0).nan?]").should eq "[true, true]"
    end

    it "still raises ZeroDivisionError for Integers" do
      builtin_outcome("", "5 % 0").should eq "ZeroDivisionError"
    end
  end

  describe "a block-taking method without a block" do
    it "raises U022, since Adjutant has no Enumerator" do
      {"[1].each", "[1].map", "[1].select", "[1].reject", "[1].sort_by", "{a: 1}.each",
       "(1..2).each", "(1..5).step(2)", "3.times", %("a\\nb".each_line)}.each do |src|
        builtin_error_code(src).should eq "U022"
      end
    end
  end

  describe "Array#join" do
    it "joins nested Arrays recursively" do
      builtin_outcome("", %([1, [2, [3]]].join(","))).should eq %("1,2,3")
    end

    it "uses each element's own to_s" do
      builtin_outcome(%(class P\n  def to_s\n    "p"\n  end\nend), %([P.new, nil, :s].join("-"))).should eq %("p--s")
    end
  end

  describe "String#split" do
    it "drops trailing empty fields and keeps leading ones" do
      builtin_outcome("", %("a,b,,".split(","))).should eq %(["a", "b"])
      builtin_outcome("", %(",a".split(","))).should eq %(["", "a"])
      builtin_outcome("", %("".split(","))).should eq "[]"
    end

    it "treats a single space, or no separator, as a whitespace split" do
      builtin_outcome("", %(" a  b ".split(" "))).should eq %(["a", "b"])
      builtin_outcome("", %(" a  b ".split)).should eq %(["a", "b"])
    end

    it "caps fields with a positive limit and keeps trailing empties with a negative one" do
      builtin_outcome("", %("a,b,c".split(",", 2))).should eq %(["a", "b,c"])
      builtin_outcome("", %("a b  c".split(" ", 2))).should eq %(["a", "b  c"])
      builtin_outcome("", %("a,b,,".split(",", -1))).should eq %(["a", "b", "", ""])
    end

    it "splits into characters with an empty separator, and keeps Regexp captures" do
      builtin_outcome("", %("abc".split(""))).should eq %(["a", "b", "c"])
      builtin_outcome("", %("a1b".split(/(\\d)/))).should eq %(["a", "1", "b"])
    end
  end

  describe "String#each_line with an empty separator" do
    it "splits into paragraphs" do
      builtin_outcome(%(r = []\n"a\\nb\\n\\nc\\n".each_line("") { |l| r.push(l) }), "r")
        .should eq %(["a\\nb\\n\\n", "c\\n"])
    end
  end

  describe "Regexp and MatchData" do
    it "gives nil for Regexp#match(nil)" do
      builtin_outcome("", "/a/.match(nil)").should eq "nil"
    end

    it "raises IndexError for an unknown group name" do
      builtin_outcome("", %(/(?<x>a)/.match("a")[:y])).should eq "IndexError"
    end

    it "doesn't capture unnamed groups in a pattern with named ones" do
      builtin_outcome("", %(/(a)(?<b>b)/.match("ab")[1])).should eq %("b")
      builtin_outcome("", %(/(a)(?<b>b)/.match("ab").captures)).should eq %(["b"])
    end
  end

  describe "methods Ruby doesn't have" do
    it "doesn't offer Range#exclusive?, only exclude_end?" do
      builtin_outcome("", "(1...2).exclusive?").should eq "NoMethodError"
      builtin_outcome("", "(1...2).exclude_end?").should eq "true"
    end
  end

  describe "inject and reduce with a Symbol" do
    it "call the named method across the elements" do
      builtin_outcome("", "[1, 2, 3].inject(:+)").should eq "6"
      builtin_outcome("", "[2, 3].reduce(:*)").should eq "6"
      builtin_outcome("", %(["a", "b"].inject(:+))).should eq %("ab")
      builtin_outcome("", "[[1], [2]].inject(:+)").should eq "[1, 2]"
      builtin_outcome("", "[].inject(:+)").should eq "nil"
    end

    it "start from an initial value before the Symbol" do
      builtin_outcome("", "[1, 2, 3].reduce(10, :+)").should eq "16"
    end
  end

  describe "Array and Hash ==" do
    it "compare nested Ranges with Ruby's ==" do
      builtin_outcome("", "[1..2] == [1..2]").should eq "true"
      builtin_outcome("", "{a: 1..2} == {a: 1..2}").should eq "true"
    end
  end
end
