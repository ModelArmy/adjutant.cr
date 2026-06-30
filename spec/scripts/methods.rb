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
