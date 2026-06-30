require "assert"

def fib(n)
  return n if n < 2
  fib(n -1) + fib(n - 2)
end

value = assert_result_is(55) do
  fib(10)
end
