require "../../spec_helper"

module Adjutant
  # Runs `src` as a method body and returns its result's `inspect`.
  private def self.precedence_outcome(src : String) : String
    eval("def run_precedence_case\n#{src}\nend\nrun_precedence_case.inspect").as_string
  end

  describe "operator precedence" do
    it "puts `and` and `or` below assignment" do
      precedence_outcome("x = false or true\nx").should eq "false"
      precedence_outcome("x = true and false\nx").should eq "true"
      precedence_outcome("x = y = 1 or 2\n[x, y]").should eq "[1, 1]"
    end

    it "gives `and` and `or` the same precedence, left to right" do
      precedence_outcome("true or false and false").should eq "false"
    end

    it "binds `&` tighter than `|` and `^`" do
      precedence_outcome("4 | 2 & 1").should eq "4"
      precedence_outcome("1 ^ 3 & 2").should eq "3"
    end

    it "puts ranges below `||`" do
      precedence_outcome("1..nil || 5").should eq "1..5"
    end

    it "puts `not` below `==`" do
      precedence_outcome("not 1 == 2").should eq "true"
    end

    it "puts `and` and `or` below an index assignment, as below any other" do
      eval("h = {}\nh[:k] = nil or 5\nh[:k].inspect").as_string.should eq "nil"
      eval("h = {}\nh[:k] = 1 and 5\nh[:k].inspect").as_string.should eq "1"
    end

    it "keeps `||` and the ternary above assignment" do
      precedence_outcome("x = nil || 5\nx").should eq "5"
      precedence_outcome("x = true ? 1 : 2\nx").should eq "1"
    end

    it "keeps `and` and `or` out of a paren-less call's arguments" do
      setup = "def save(x)\n  false\nend\nlog = []\n"
      eval(setup + "save 1 or log.push(:fallback)\nlog.inspect").as_string.should eq "[:fallback]"
      eval(setup + "save 1 and log.push(:after)\nlog.inspect").as_string.should eq "[]"
    end

    it "rejects `and` and `or` inside a call's parentheses, as Ruby does" do
      expect_raises(ParseError) { Parser.new("f(a or b)", "t.rb").parse }
      expect_raises(ParseError) { Parser.new("f(k: a and b)", "t.rb").parse }
    end

    it "keeps `and` and `or` out of `yield`'s arguments without parentheses" do
      src = <<-RUBY
      def fallback
        yield 1 or :fallback
      end

      def after
        yield 1 and :after
      end

      seen = []
      results = [fallback { |x| seen.push(x) && nil }, after { |x| seen.push(x) }]
      [seen, results].inspect
      RUBY
      eval(src).as_string.should eq "[[1, 1], [:fallback, :after]]"
    end

    it "keeps `and` and `or` out of `super`'s arguments without parentheses" do
      src = <<-RUBY
      class Recorder
        def take(x)
          [x]
        end

        def drop(x)
          nil
        end
      end

      class Relay < Recorder
        def take(x)
          super x and :after
        end

        def drop(x)
          super x or :fallback
        end
      end
      [Relay.new.take(1), Relay.new.drop(1)].inspect
      RUBY
      eval(src).as_string.should eq "[:after, :fallback]"
    end

    it "keeps `and` and `or` out of `raise`'s arguments without parentheses" do
      src = <<-RUBY
      begin
        raise "first" and "second"
      rescue => e
        e.message
      end
      RUBY
      eval(src).as_string.should eq "first"
    end

    it "rejects `and` and `or` inside `yield`, `super` and `raise` parentheses, as Ruby does" do
      {
        "def m\n  yield(a or b)\nend",
        "def m(a)\n  super(a and b)\nend",
        "raise(a or b)",
      }.each do |src|
        expect_raises(ParseError) { Parser.new(src, "t.rb").parse }
      end
    end

    it "still allows them in a parenthesised expression passed as an argument" do
      eval("def f(x)\n  x\nend\nf (nil or 5)").as_int.should eq 5
    end

    it "rejects chaining a non-associative operator (P008)" do
      {"1 == 1 == true", "1..2..3", "1 <=> 2 == 0"}.each do |src|
        error = expect_raises(ParseError) { Parser.new(src, "t.rb").parse }
        error.diagnostic.not_nil!.code.should eq "P008"
      end
    end
  end
end
