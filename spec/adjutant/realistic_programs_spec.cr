require "../spec_helper"

module Adjutant
  describe Parser do
    describe "a realistic program" do
      it "parses a multi-statement program" do
        src = <<-RUBY
          def fib(n)
            return n if n < 2
            fib(n - 1) + fib(n - 2)
          end
          puts(fib(10))
        RUBY
        body = parse(src)
        body.stmts.size.should eq 2
        body.stmts[0].should be_a(DefNode)
        body.stmts[1].should be_a(Call)
      end
    end
  end

  describe Compiler do
    describe "a realistic program" do
      it "compiles fib without error" do
        src = "def fib(n)\nreturn n if n < 2\nfib(n - 1) + fib(n - 2)\nend\nputs(fib(10))"
        chunk = compile(src)
        chunk.code.should_not be_empty
      end
    end
  end

  describe Interpreter do
    describe "realistic programs" do
      it "computes fibonacci iteratively" do
        src = <<-RUBY
          a = 0
          b = 1
          i = 0
          while i < 10
            tmp = a + b
            a = b
            b = tmp
            i += 1
          end
          a
        RUBY
        # fib(10) = 55
        eval(src).as_int.should eq 55_i64
      end

      it "sums an array" do
        src = <<-RUBY
        arr = [1, 2, 3, 4, 5]
        sum = 0
        i = 0
        while i < 5
          sum += arr[i]
          i += 1
        end
        sum
        RUBY
        eval(src).as_int.should eq 15_i64
      end
    end
  end
end
