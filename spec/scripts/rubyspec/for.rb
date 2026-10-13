# Derived from ruby/spec language/for_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

module ScratchPad
  STORE = [nil]

  def self.record(value)
    STORE[0] = value
  end

  def self.recorded
    STORE[0]
  end

  def self.clear
    STORE[0] = nil
  end
end

# Fixture: ruby/spec language/fixtures/for_scope.rb
module ForSpecs
  class ForInClassMethod
    m = :same_variable_set_outside

    def self.foo
      all = []
      for m in [:bar, :baz]
        all << m
      end
      all
    end

    READER = -> { m }
  end
end


assert("The for expression iterates over an Enumerable passing each element to the block") do
  j = 0
  for i in 1..3
    j += i
  end
  assert_equal(6, j)
end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression iterates over a list of arrays and destructures with empty comma") do
#   for i, in [[1,2]]
#     assert_equal(1, i)
#   end
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression iterates over a list of arrays and destructures with an empty splat") do
#   for i, * in [[1,2]]
#     assert_equal(1, i)
#   end
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression iterates over a list of arrays and destructures with a splat") do
#   for i, *j in [[1,2]]
#     assert_equal(1, i)
#     assert_equal([2], j)
#   end
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression iterates over a list of arrays and destructures with a splat and additional targets") do
#   for i, *j, k in [[1,2,3,4]]
#     assert_equal(1, i)
#     assert_equal([2,3], j)
#     assert_equal(4, k)
#   end
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression iterates over a list of arrays and destructures with a multi-assignment") do
#   for (i, j, k) in [[1,2,3]]
#     assert_equal([1, 2, 3], [i, j, k])
#   end
#
#   for i, (j, k) in [[1,[2,3]]]
#     assert_equal([1, 2, 3], [i, j, k])
#   end
#
# end

assert("The for expression iterates over an Hash passing each key-value pair to the block") do
  k = 0
  l = 0

  for i, j in { 1 => 10, 2 => 20 }
    k += i
    l += j
  end

  assert_equal(3, k)
  assert_equal(30, l)
end

# --- BLOCKED: `def obj.each` on an instance defines a class method
# (SCOPE.md, Must Fix).
# assert("The for expression iterates over any object responding to 'each'") do
#   obj = Object.new
#   def obj.each
#     (0..10).each { |i| yield i }
#   end
#
#   j = 0
#   for i in obj
#     j += i
#   end
#   assert_equal(55, j)
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression allows an instance variable as an iterator name") do
#   m = [1,2,3]
#   n = 0
#   for @var in m
#     n += 1
#   end
#   assert_equal(3, @var)
#   assert_equal(3, n)
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression allows a class variable as an iterator name") do
#   class OFor
#     m = [1,2,3]
#     n = 0
#     for @@var in m
#       n += 1
#     end
#     assert_equal(3, @@var)
#     assert_equal(3, n)
#   end
# end

# --- BLOCKED: tests a constant warning, which Adjutant doesn't emit;
# constants are assign-once (U003).
# assert("The for expression allows a constant as an iterator name") do
#   class OFor
#     m = [1,2,3]
#     n = 0
#     -> {
#       for CONST in m
#         n += 1
#       end
#     }.should complain(/already initialized constant/)  # TODO(convert)
#     assert_equal(3, CONST)
#     assert_equal(3, n)
#   end
# end

# --- BLOCKED: uses `$` globals (U011).
# assert("The for expression allows a global variable as an iterator name") do
#   old_global_var = $var
#   m = [1,2,3]
#   n = 0
#   for $var in m
#     n += 1
#   end
#   assert_equal(3, $var)
#   assert_equal(3, n)
#   $var = old_global_var
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression allows an attribute as an iterator name") do
#   class OFor
#     attr_accessor :target
#   end
#
#   ofor = OFor.new
#   m = [1,2,3]
#   n = 0
#   for ofor.target in m
#     n += 1
#   end
#   assert_equal(3, ofor.target)
#   assert_equal(3, n)
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression allows an attribute with safe navigation as an iterator name") do
#   class OFor
#     attr_accessor :target
#   end
#
#   ofor = OFor.new
#   m = [1,2,3]
#   n = 0
#   for ofor&.target in m
#     n += 1
#   end
#   assert_equal(3, ofor.target)
#   assert_equal(3, n)
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression allows an attribute with safe navigation on a nil base as an iterator name") do
#   ofor = nil
#   m = [1,2,3]
#   n = 0
#   for ofor&.target in m
#     n += 1
#   end
#   assert_equal(nil, ofor)
#   assert_equal(3, n)
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression allows an array index writer as an iterator name") do
#   arr = [:a, :b, :c]
#   m = [1,2,3]
#   n = 0
#   for arr[1] in m
#     n += 1
#   end
#   assert_equal([:a, 3, :c], arr)
#   assert_equal(3, n)
# end

# --- BLOCKED: `for` reads its targets as local names (SCOPE.md, Must
# Fix).
# assert("The for expression allows a hash index writer as an iterator name") do
#   hash = { a: 10, b: 20, c: 30 }
#   m = [1,2,3]
#   n = 0
#   for hash[:b] in m
#     n += 1
#   end
#   assert_equal({ a: 10, b: 3, c: 30 }, hash)
#   assert_equal(3, n)
# end

assert("The for expression yields only as many values as there are arguments") do
  class OFor
    def each
      [[1,2,3], [4,5,6]].each do |a|
        yield(a[0],a[1],a[2])
      end
    end
  end
  o = OFor.new
  qs = []
  for q in o
    qs << q
  end
  assert_equal([1, 4], qs)
  assert_equal(4, q)
end

assert("The for expression optionally takes a 'do' after the expression") do
  j = 0
  for i in 1..3 do
    j += i
  end
  assert_equal(6, j)
end

assert("The for expression allows body begin on the same line if do is used") do
  j = 0
  for i in 1..3 do j += i
  end
  assert_equal(6, j)
end

assert("The for expression declares iteration variables in the surrounding variable scope") do
  for a, b in [[1,2]]
  end

  assert_equal(1, a)
  assert_equal(2, b)
end

assert("The for expression declares variables in the body in the surrounding variable scope") do
  for i in 1..2
    a = 123
  end

  assert_equal(123, a)
end

assert("The for expression declares variables in the body in the surrounding variable scope with 'do'") do
  for i in 1..2 do
    a = 123
  end

  assert_equal(123, a)
end

# --- BLOCKED: `Kernel#local_variables` doesn't exist (SCOPE.md,
# Standard library surface).
# assert("The for expression declares variables inside a block as normal") do
#   for i in 1..2 do
#     -> {
#       inside_proc = 42
#     }.call
#   end
#   assert_equal([:i], local_variables)
# end

# --- BLOCKED: `Kernel#local_variables` doesn't exist (SCOPE.md,
# Standard library surface).
# assert("The for expression declares variables inside a lambda as normal") do
#   for i in 1..2 do
#     -> {
#       inside_proc = 42
#     }.call
#   end
#   assert_equal([:i], local_variables)
# end

# --- BLOCKED: `Kernel#local_variables` doesn't exist (SCOPE.md,
# Standard library surface).
# assert("The for expression can be nested") do
#   for a in [6]
#     for b in [7]
#       c = a * b
#     end
#   end
#   assert_equal([:a, :b, :c], local_variables.sort)
#   assert_equal(42, c)
# end

# --- BLOCKED: `Kernel#local_variables` doesn't exist (SCOPE.md,
# Standard library surface).
# assert("The for expression can be nested with blocks in between") do
#   # This is an edge case spec for Ruby implementations which have
#   # their own runtime scope per for loop body (like YARV and TruffleRuby)
#   for a in [1]
#     a1 = a
#     assert_equal(a, a1)
#     for b in [2]
#       b1 = b
#       assert_equal(a, a1)
#       assert_equal(b, b1)
#       -> {
#         inside_proc = 42
#
#         assert_equal(a, a1)
#         assert_equal(b, b1)
#         assert_equal(42, inside_proc)
#
#         for c in [3].map { |enum_var|
#           assert_equal(a, a1)
#           assert_equal(b, b1)
#           assert_equal(42, inside_proc)
#           enum_var
#         }
#           c1 = c
#
#           assert_equal(a, a1)
#           assert_equal(b, b1)
#           assert_equal(c, c1)
#           assert_equal(42, inside_proc)
#
#           for d in [4]
#             d1 = d
#
#             assert_equal(a, a1)
#             assert_equal(b, b1)
#             assert_equal(c, c1)
#             assert_equal(d, d1)
#             assert_equal(42, inside_proc)
#           end
#         end
#         assert_equal([:a, :a1, :b, :b1, :c, :c1, :d, :d1, :inside_proc], local_variables.sort)
#       }.call
#     end
#   end
#   assert_equal([:a, :a1, :b, :b1], local_variables.sort)
# end

# --- BLOCKED: argument forwarding with `...` doesn't work (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The for expression can be nested with forward arguments") do
#   def bar(*args)
#     args
#   end
#
#   def foo(...)
#     for a in [1]
#       r = bar(...)
#     end
#     r
#   end
#
#   assert_equal([2, 3], foo(2, 3))
# end

assert("The for expression does not try to access variables outside the method") do
  assert_equal([:bar, :baz], ForSpecs::ForInClassMethod.foo)
  assert_equal(:same_variable_set_outside, ForSpecs::ForInClassMethod::READER.call)
end

# --- BLOCKED: `for` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The for expression returns expr") do
#   assert_equal((1..3), for i in 1..3; end)
#   assert_equal({ 1 => 10, 2 => 20 }, for i,j in { 1 => 10, 2 => 20 }; end)
# end

# --- BLOCKED: `for` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The for expression breaks out of a loop upon 'break', returning nil") do
#   j = 0
#   result = for i in 1..3
#     j += i
#
#     break if i == 2
#   end
#   assert_equal(nil, result)
#
#   assert_equal(3, j)
# end

# --- BLOCKED: `for` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The for expression allows 'break' to have an argument which becomes the value of the for expression") do
#   result = for i in 1..3
#     break 10 if i == 2
#   end
#   assert_equal(10, result)
# end

assert("The for expression starts the next iteration with 'next'") do
  j = 0
  for i in 1..5
    next if i == 2

    j += i
  end

  assert_equal(13, j)
end

# --- BLOCKED: `redo` in a block, a lambda or a `for` raises C002 (SCOPE.md, Parser
# / lexer gaps).
# assert("The for expression repeats current iteration with 'redo'") do
#   j = 0
#   for i in 1..3
#     j += i
#
#     if i == 2 && j < 4
#       redo
#     end
#   end
#
#   assert_equal(8, j)
# end
