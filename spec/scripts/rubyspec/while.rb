# Derived from ruby/spec language/while_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

class WhileSpecAttribute
  attr_reader :reads, :writes

  def initialize
    @reads = 0
    @writes = 0
  end

  def m
    @reads += 1
    nil
  end

  def m=(value)
    @writes += 1
  end
end

assert("The while expression runs while the expression is true") do
  i = 0
  while i < 3
    i += 1
  end
  assert_equal(3, i)
end

assert("The while expression optionally takes a 'do' after the expression") do
  i = 0
  while i < 3 do
    i += 1
  end

  assert_equal(3, i)
end

assert("The while expression allows body begin on the same line if do is used") do
  i = 0
  while i < 3 do i += 1
  end

  assert_equal(3, i)
end

assert("The while expression executes code in containing variable scope") do
  i = 0
  while i != 1
    a = 123
    i = 1
  end

  assert_equal(123, a)
end

assert("The while expression executes code in containing variable scope with 'do'") do
  i = 0
  while i != 1 do
    a = 123
    i = 1
  end

  assert_equal(123, a)
end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression returns nil if ended when condition became false") do
#   i = 0
#   result = while i < 3
#     i += 1
#   end
#   assert_equal(nil, result)
# end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The while expression does not evaluate the body if expression is empty") do
#   a = []
#   while ()
#     a << :body_evaluated
#   end
#   assert_equal([], a)
# end

assert("The while expression stops running body if interrupted by break") do
  i = 0
  while i < 10
    i += 1
    break if i > 5
  end
  assert_equal(6, i)
end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break in a parenthesized element op-assign-or value") do
#   c = true
#   a = []
#   result = while c
#     a[1] ||=
#       (
#         break if c
#         c = false
#       )
#   end
#   assert_equal(nil, result)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break in a begin ... end element op-assign-or value") do
#   c = true
#   a = []
#   result = while c
#     a[1] ||= begin
#       break if c
#       c = false
#     end
#   end
#   assert_equal(nil, result)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break in a parenthesized element op-assign value") do
#   c = true
#   a = [1, 2]
#   result = while c
#     a[1] +=
#       (
#         break if c
#         c = false
#       )
#   end
#   assert_equal(nil, result)
#   assert_equal([1, 2], a)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break in a begin ... end element op-assign value") do
#   c = true
#   a = [1, 2]
#   result = while c
#     a[1] += begin
#       break if c
#       c = false
#     end
#   end
#   assert_equal(nil, result)
#   assert_equal([1, 2], a)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break with unless in a parenthesized attribute op-assign-or value") do
#   a = WhileSpecAttribute.new
#
#   c = d = true
#   result = while c
#     a.m ||=
#       (
#         break unless d
#         d = false
#       )
#   end
#   assert_equal(nil, result)
#   assert_equal(2, a.reads)
#   assert_equal(1, a.writes)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break with unless in a begin ... end attribute op-assign-or value") do
#   a = WhileSpecAttribute.new
#
#   c = d = true
#   result = while c
#     a.m ||= begin
#       break unless d
#       d = false
#     end
#   end
#   assert_equal(nil, result)
#   assert_equal(2, a.reads)
#   assert_equal(1, a.writes)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break in a parenthesized attribute op-assign-or value") do
#   a = WhileSpecAttribute.new
#
#   c = true
#   result = while c
#     a.m +=
#       (
#         break if c
#         c = false
#       )
#   end
#   assert_equal(nil, result)
#   assert_equal(1, a.reads)
#   assert_equal(0, a.writes)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression stops running body if interrupted by break in a begin ... end attribute op-assign-or value") do
#   a = WhileSpecAttribute.new
#
#   c = true
#   result = while c
#     a.m += begin
#       break if c
#       c = false
#     end
#   end
#   assert_equal(nil, result)
#   assert_equal(1, a.reads)
#   assert_equal(0, a.writes)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression returns value passed to break if interrupted by break") do
#   result = while true
#     break 123
#   end
#   assert_equal(123, result)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The while expression returns nil if interrupted by break with no arguments") do
#   result = while true
#     break
#   end
#   assert_equal(nil, result)
# end

assert("The while expression skips to end of body with next") do
  a = []
  i = 0
  while (i+=1)<5
    next if i==3
    a << i
  end
  assert_equal([1, 2, 4], a)
end

assert("The while expression restarts the current iteration without reevaluating condition with redo") do
  a = []
  i = 0
  j = 0
  while (i+=1)<3
    a << i
    j+=1
    if j<3
      redo
    end
  end
  assert_equal([1, 1, 1, 2], a)
end

assert("The while modifier runs preceding statement while the condition is true") do
  i = 0
  i += 1 while i < 3
  assert_equal(3, i)
end

assert("The while modifier evaluates condition before statement execution") do
  a = []
  i = 0
  a << i while (i+=1) < 3
  assert_equal([1, 2], a)
end

assert("The while modifier does not run preceding statement if the condition is false") do
  i = 0
  i += 1 while false
  assert_equal(0, i)
end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The while modifier does not run preceding statement if the condition is empty") do
#   i = 0
#   i += 1 while ()
#   assert_equal(0, i)
# end

# --- BLOCKED: parentheses hold exactly one expression (SCOPE.md, Parser
# / lexer gaps).
# assert("The while modifier returns nil if ended when condition became false") do
#   i = 0
#   assert_equal(nil, (i += 1 while i<10))
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `break` (SCOPE.md, Parser / lexer gaps).
# assert("The while modifier returns value passed to break if interrupted by break") do
#   assert_equal(123, (break 123 while true))
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `break` (SCOPE.md, Parser / lexer gaps).
# assert("The while modifier returns nil if interrupted by break with no arguments") do
#   assert_equal(nil, (break while true))
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `next` (SCOPE.md, Parser / lexer gaps).
# assert("The while modifier skips to end of body with next") do
#   i = 0
#   j = 0
#   ((i+=1) == 3 ? next : j+=i) while i <= 10
#   assert_equal(63, j)
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `redo` (SCOPE.md, Parser / lexer gaps).
# assert("The while modifier restarts the current iteration without reevaluating condition with redo") do
#   i = 0
#   j = 0
#   (i+=1) == 4 ? redo : j+=i while (i+=1) <= 10
#   assert_equal(34, j)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block runs block while the expression is true") do
#   i = 0
#   begin
#     i += 1
#   end while i < 3
#
#   assert_equal(3, i)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block stops running block if interrupted by break") do
#   i = 0
#   begin
#     i += 1
#     break if i > 5
#   end while i < 10
#
#   assert_equal(6, i)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block returns value passed to break if interrupted by break") do
#   assert_equal(123, (begin; break 123; end while true))
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block returns nil if interrupted by break with no arguments") do
#   assert_equal(nil, (begin; break; end while true))
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block runs block at least once (even if the expression is false)") do
#   i = 0
#   begin
#     i += 1
#   end while false
#
#   assert_equal(1, i)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block evaluates condition after block execution") do
#   a = []
#   i = 0
#   begin
#     a << i
#   end while (i+=1)<5
#   assert_equal([0, 1, 2, 3, 4], a)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block skips to end of body with next") do
#   a = []
#   i = 0
#   begin
#     next if i==3
#     a << i
#   end while (i+=1)<5
#   assert_equal([0, 1, 2, 4], a)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The while modifier with begin .. end block restarts the current iteration without reevaluating condition with redo") do
#   a = []
#   i = 0
#   j = 0
#   begin
#     a << i
#     j+=1
#     redo if j<3
#   end while (i+=1)<3
#   assert_equal([0, 0, 0, 1, 2], a)
# end
