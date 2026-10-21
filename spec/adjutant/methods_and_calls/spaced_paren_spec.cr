require "../../spec_helper"

module Adjutant
  # The class and message of what `source` raises, as `inspect` prints
  # them.
  private def self.spaced_paren_raised(source : String) : String
    eval("begin\n#{source}\n:missed\nrescue Exception => e\n[e.class, e.message].inspect\nend").as_string
  end

  describe "a spaced `(` after a call's name, as Ruby's tLPAREN_ARG" do
    describe "after yield" do
      it "starts the first argument, so an operator after it is part of the argument" do
        src = <<-RUBY
        def twice
          yield (2) * 10
        end
        twice { |n| n + 1 }.inspect
        RUBY
        eval(src).as_string.should eq "21"
      end

      it "starts the first argument, so a method call after it is part of the argument" do
        src = <<-RUBY
        def show
          yield (2).to_s
        end
        show { |text| text.class }.inspect
        RUBY
        eval(src).as_string.should eq "String"
      end

      it "starts the first of several arguments in an assignment's value" do
        src = <<-RUBY
        def pair
          got = yield (1), 2
          got
        end
        pair { |first, second| [first, second] }.inspect
        RUBY
        eval(src).as_string.should eq "[1, 2]"
      end

      it "keeps an unspaced ( as the argument list" do
        src = <<-RUBY
        def twice
          yield(2) * 10
        end
        twice { |n| n + 1 }.inspect
        RUBY
        eval(src).as_string.should eq "30"
      end
    end

    describe "after super" do
      it "starts the first argument, so an operator after it is part of the argument" do
        src = <<-RUBY
        class Base
          def scale(n)
            n * 10
          end
        end

        class Child < Base
          def scale(n)
            super (n) + 1
          end
        end
        Child.new.scale(2).inspect
        RUBY
        eval(src).as_string.should eq "30"
      end
    end

    describe "after raise" do
      it "starts the first argument, so an operator after it is part of the argument" do
        spaced_paren_raised(%(raise ("a") + "b")).should eq %([RuntimeError, "ab"])
      end

      it "starts the first of several arguments at the start of a statement" do
        spaced_paren_raised(%(raise (ArgumentError), "bad")).should eq %([ArgumentError, "bad"])
      end
    end

    describe "after a receiver's method" do
      it "starts the first argument, so an operator after it is part of the argument" do
        eval(%(found = "ab".start_with? ("x") || true\nfound.inspect)).as_string.should eq "false"
      end

      it "starts the first of several arguments in an assignment's value" do
        eval("items = [1].push (2), 3\nitems.inspect").as_string.should eq "[1, 2, 3]"
      end

      it "keeps an unspaced ( as the argument list" do
        eval(%(found = "ab".start_with?("x") || true\nfound.inspect)).as_string.should eq "true"
      end
    end
  end
end
