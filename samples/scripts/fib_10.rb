require "assert"

def fib(n)
  return n if n < 2
  fib(n -1) + fib(n - 2)
end

value = fib(10)

assert_equal(value, 55)
value
