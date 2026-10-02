require "../../spec_helper"

module Adjutant
  # Runs `setup`, then `call` inside `begin`/`rescue ArgumentError`, and
  # returns the error's message, or "no ArgumentError" if none was
  # raised.
  private def self.argument_error_message(setup : String, call : String) : String
    eval(<<-RUBY).as_string
      #{setup}
      begin
        #{call}
        "no ArgumentError"
      rescue ArgumentError => e
        e.message
      end
      RUBY
  end

  # The code of the ParseError `source` raises.
  private def self.parse_error_code(source : String) : String
    Parser.new(source, "t.rb").parse
    raise "no ParseError for #{source.inspect}"
  rescue ex : ParseError
    ex.diagnostic.not_nil!.code
  end

  describe "positional arity" do
    describe "script methods" do
      it "raises for a missing argument" do
        argument_error_message("def f(a, b); [a, b]; end", "f(1)")
          .should eq "wrong number of arguments (given 1, expected 2)"
      end

      it "raises for an extra argument" do
        argument_error_message("def f(a, b); [a, b]; end", "f(1, 2, 3)")
          .should eq "wrong number of arguments (given 3, expected 2)"
      end

      it "raises for any argument to a method with no parameters" do
        argument_error_message("def f; 1; end", "f(1)")
          .should eq "wrong number of arguments (given 1, expected 0)"
      end

      it "reports a range when there are optional parameters" do
        argument_error_message("def f(a, b = 2); [a, b]; end", "f")
          .should eq "wrong number of arguments (given 0, expected 1..2)"
        argument_error_message("def f(a, b = 2); [a, b]; end", "f(1, 2, 3)")
          .should eq "wrong number of arguments (given 3, expected 1..2)"
      end

      it "reports a minimum when there is a splat, and accepts any number above it" do
        argument_error_message("def f(a, *r); [a, r]; end", "f")
          .should eq "wrong number of arguments (given 0, expected 1+)"
        eval("def f(a, *r); [a, r]; end\nf(1, 2, 3).inspect").as_string.should eq "[1, [2, 3]]"
      end

      it "names required keywords, and checks arity before them" do
        argument_error_message("def f(a, b:); a; end", "f(b: 1)")
          .should eq "wrong number of arguments (given 0, expected 1; required keyword: b)"
        argument_error_message("def f(a, b:, c:); a; end", "f")
          .should eq "wrong number of arguments (given 0, expected 1; required keywords: b, c)"
      end

      it "checks instance methods, singleton methods and super" do
        setup = <<-RUBY
          class A
            def m(x); x; end
            def self.s(x); x; end
          end
          class B < A
            def m; super(1, 2); end
          end
          RUBY
        argument_error_message(setup, "A.new.m").should eq "wrong number of arguments (given 0, expected 1)"
        argument_error_message(setup, "A.s(1, 2)").should eq "wrong number of arguments (given 2, expected 1)"
        argument_error_message(setup, "B.new.m").should eq "wrong number of arguments (given 2, expected 1)"
      end

      it "checks `new` against `initialize`, or against none" do
        argument_error_message("class P; end", "P.new(1)")
          .should eq "wrong number of arguments (given 1, expected 0)"
        argument_error_message("class Q; def initialize(a); end; end", "Q.new")
          .should eq "wrong number of arguments (given 0, expected 1)"
      end

      it "raises R046 as an ArgumentError" do
        error = expect_raises(RuntimeError) { eval("def f(a); a; end\nf") }
        error.diagnostic.not_nil!.code.should eq "R046"
      end
    end

    describe "lambdas" do
      it "raise for a missing or extra argument" do
        argument_error_message("l = ->(a, b) { [a, b] }", "l.call(1)")
          .should eq "wrong number of arguments (given 1, expected 2)"
        argument_error_message("l = ->(a, b) { [a, b] }", "l.call(1, 2, 3)")
          .should eq "wrong number of arguments (given 3, expected 2)"
        argument_error_message("l = ->(a, b = 2) { [a, b] }", "l.call")
          .should eq "wrong number of arguments (given 0, expected 1..2)"
      end

      it "are strict when written as `lambda { }`" do
        argument_error_message("l = lambda { |a, b| [a, b] }", "l.call(1)")
          .should eq "wrong number of arguments (given 1, expected 2)"
      end

      it "don't spread a lone Array across their parameters" do
        argument_error_message("l = ->(a, b) { [a, b] }", "l.call([1, 2])")
          .should eq "wrong number of arguments (given 1, expected 2)"
      end

      it "are strict when matched by `case`/`when`" do
        argument_error_message("", "case 5\nwhen ->(a, b) { true } then :hit\nend")
          .should eq "wrong number of arguments (given 1, expected 2)"
      end
    end

    describe "blocks" do
      it "drop extra arguments and pad missing ones with nil" do
        eval("def m; yield(1, 2, 3); end\nm { |a| a }").as_int.should eq 1
        eval("def m; yield; end\nm { |a, b| [a, b] }.inspect").as_string.should eq "[nil, nil]"
        eval("[1, 2].map { |a, b| b }.inspect").as_string.should eq "[nil, nil]"
        eval("[[1, 2]].map { |a, b| b }.inspect").as_string.should eq "[2]"
      end
    end

    describe "native methods and functions" do
      it "raise for a missing argument" do
        argument_error_message("", "[1].include?").should eq "wrong number of arguments (given 0, expected 1)"
        argument_error_message("", "{a: 1}.key?").should eq "wrong number of arguments (given 0, expected 1)"
      end

      it "raise for an extra argument" do
        argument_error_message("", "[1].size(1)").should eq "wrong number of arguments (given 1, expected 0)"
        argument_error_message("", "5.abs(1)").should eq "wrong number of arguments (given 1, expected 0)"
        argument_error_message("", "[1, 2].first(1, 2)").should eq "wrong number of arguments (given 2, expected 0..1)"
        argument_error_message("", "5.round(1, 2)").should eq "wrong number of arguments (given 2, expected 0..1)"
        argument_error_message("", %("a,b".split(",", 1, 2))).should eq "wrong number of arguments (given 3, expected 0..2)"
        argument_error_message("", "lambda(1) { }").should eq "wrong number of arguments (given 1, expected 0)"
      end

      it "raise for operations every object has" do
        argument_error_message("", "5.nil?(1)").should eq "wrong number of arguments (given 1, expected 0)"
        argument_error_message("", "5.is_a?").should eq "wrong number of arguments (given 0, expected 1)"
      end
    end
  end

  describe "positional binding order" do
    it "fills required parameters after optional ones first" do
      eval("def f(a = 1, b); [a, b]; end\nf(5).inspect").as_string.should eq "[1, 5]"
      eval("def f(a, b = 2, c); [a, b, c]; end\nf(1, 3).inspect").as_string.should eq "[1, 2, 3]"
      eval("def f(a, b = 2, c); [a, b, c]; end\nf(1, 9, 3).inspect").as_string.should eq "[1, 9, 3]"
    end

    it "fills required parameters after a splat before the splat" do
      eval("def f(*r, z); [r, z]; end\nf(1, 2, 3).inspect").as_string.should eq "[[1, 2], 3]"
      eval("def f(a, *r, z); [a, r, z]; end\nf(1, 2).inspect").as_string.should eq "[1, [], 2]"
      eval("def f(a = 1, *r, z); [a, r, z]; end\nf(9).inspect").as_string.should eq "[1, [], 9]"
      eval("def f(a = 1, *r, z); [a, r, z]; end\nf(8, 9).inspect").as_string.should eq "[8, [], 9]"
      argument_error_message("def f(*r, z); z; end", "f")
        .should eq "wrong number of arguments (given 0, expected 1+)"
    end

    it "binds a lambda's parameters in the same order" do
      eval("->(a = 1, b) { [a, b] }.call(5).inspect").as_string.should eq "[1, 5]"
    end
  end

  describe "parameter list validation" do
    it "rejects parameters out of Ruby's order (P006)" do
      parse_error_code("def f(a = 1, b, c = 2); end").should eq "P006"
      parse_error_code("def f(*a, b = 1); end").should eq "P006"
      parse_error_code("def f(*a, *b); end").should eq "P006"
      parse_error_code("def f(a:, b); end").should eq "P006"
      parse_error_code("->(a:, b) { }").should eq "P006"
      parse_error_code("[1].each { |a:, b| }").should eq "P006"
    end

    it "rejects a duplicated parameter name (P007)" do
      parse_error_code("def f(a, a); end").should eq "P007"
      parse_error_code("->(a, a) { }").should eq "P007"
      parse_error_code("[1].each { |a, a| }").should eq "P007"
    end

    it "allows duplicated names that start with an underscore, as Ruby does" do
      eval("def f(_, _); 1; end\nf(2, 3)").as_int.should eq 1
      eval("[[1, 2]].map { |_x, _x| 7 }.inspect").as_string.should eq "[7]"
    end
  end
end
