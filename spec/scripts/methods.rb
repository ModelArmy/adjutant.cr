require "assert"

def add(a, b)
  a + b
end

assert("call simple method: add") do
  add(3, 4) == 7
end

def fact(n)
  return 1 if n < 2
  n * fact(n - 1)
end

assert("call recursive method: factorial") do
  fact(5) == 120
end

def fib(n)
  return n if n < 2
  fib(n - 1) + fib(n - 2)
end

assert("call recursive method: fibonacci") do
  fib(10) == 55
end

def double(n)
  result = n * 2
  result
end

assert("call simple method: double") do
  42 == double(21)
end

def call_block
  yield 10
end

assert("call yielding method") do
  result = call_block { |x| x * 2 }
  result == 20
end

assert("dynamically defined class method") do
  class X
    def self.add(a,b); a+b; end
  end
  7 == X.add(3,4)
end

assert("call without parents") do
  sum = add 3, 5
  sum == 8
end

# Native method call with
assert_equal(add(3, 5), 8)

# Native method calls without parens
assert_equal add(3, 5), 8
assert_equal 3+5, 8

assert "unknown bare names should raise" do
  assert_raise NameError do
    class A
      def self.greet; "hi"; end
    end

    greet
  end

  assert_raise NameError do
    class A
      def self.check; boom; end
    end

    A.check
  end
end

assert "single methods self is Class" do
  class A
    def self.hello
      assert_equal(self, A)
      "hello"
    end

    def world
      assert_not_equal(self, A)
      "world"
    end
  end

  A.hello
  A.new.world
end
