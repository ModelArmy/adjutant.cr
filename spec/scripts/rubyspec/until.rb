# Derived from ruby/spec language/until_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The until expression runs while the expression is false") do
  i = 0
  until i > 9
    i += 1
  end

  assert_equal(10, i)
end

assert("The until expression optionally takes a 'do' after the expression") do
  i = 0
  until i > 9 do
    i += 1
  end

  assert_equal(10, i)
end

assert("The until expression allows body begin on the same line if do is used") do
  i = 0
  until i > 9 do i += 1
  end

  assert_equal(10, i)
end

assert("The until expression executes code in containing variable scope") do
  i = 0
  until i == 1
    a = 123
    i = 1
  end

  assert_equal(123, a)
end

assert("The until expression executes code in containing variable scope with 'do'") do
  i = 0
  until i == 1 do
    a = 123
    i = 1
  end

  assert_equal(123, a)
end

# --- BLOCKED: `until` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The until expression returns nil if ended when condition became true") do
#   i = 0
#   result = until i > 9
#     i += 1
#   end
#   assert_equal(nil, result)
# end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The until expression evaluates the body if expression is empty") do
#   a = []
#   until ()
#     a << :body_evaluated
#     break
#   end
#   assert_equal([:body_evaluated], a)
# end

assert("The until expression stops running body if interrupted by break") do
  i = 0
  until i > 9
    i += 1
    break if i > 5
  end
  assert_equal(6, i)
end

# --- BLOCKED: `until` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The until expression returns value passed to break if interrupted by break") do
#   result = until false
#     break 123
#   end
#   assert_equal(123, result)
# end

# --- BLOCKED: `until` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The until expression returns nil if interrupted by break with no arguments") do
#   result = until false
#     break
#   end
#   assert_equal(nil, result)
# end

assert("The until expression skips to end of body with next") do
  a = []
  i = 0
  until (i+=1)>=5
    next if i==3
    a << i
  end
  assert_equal([1, 2, 4], a)
end

assert("The until expression restarts the current iteration without reevaluating condition with redo") do
  a = []
  i = 0
  j = 0
  until (i+=1)>=3
    a << i
    j+=1
    if j<3
      redo
    end
  end
  assert_equal([1, 1, 1, 2], a)
end

assert("The until modifier runs preceding statement while the condition is false") do
  i = 0
  i += 1 until i > 9
  assert_equal(10, i)
end

assert("The until modifier evaluates condition before statement execution") do
  a = []
  i = 0
  a << i until (i+=1) >= 3
  assert_equal([1, 2], a)
end

assert("The until modifier does not run preceding statement if the condition is true") do
  i = 0
  i += 1 until true
  assert_equal(0, i)
end

# --- BLOCKED: parentheses hold exactly one expression (SCOPE.md, Parser
# / lexer gaps).
# assert("The until modifier returns nil if ended when condition became true") do
#   i = 0
#   assert_equal(nil, (i += 1 until i>9))
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `break` (SCOPE.md, Parser / lexer gaps).
# assert("The until modifier returns value passed to break if interrupted by break") do
#   assert_equal(123, (break 123 until false))
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `break` (SCOPE.md, Parser / lexer gaps).
# assert("The until modifier returns nil if interrupted by break with no arguments") do
#   assert_equal(nil, (break until false))
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `next` (SCOPE.md, Parser / lexer gaps).
# assert("The until modifier skips to end of body with next") do
#   i = 0
#   j = 0
#   ((i+=1) == 3 ? next : j+=i) until i > 10
#   assert_equal(63, j)
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `redo` (SCOPE.md, Parser / lexer gaps).
# assert("The until modifier restarts the current iteration without reevaluating condition with redo") do
#   i = 0
#   j = 0
#   (i+=1) == 4 ? redo : j+=i until (i+=1) > 10
#   assert_equal(34, j)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The until modifier with begin .. end block runs block while the expression is false") do
#   i = 0
#   begin
#     i += 1
#   end until i > 9
#
#   assert_equal(10, i)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The until modifier with begin .. end block stops running block if interrupted by break") do
#   i = 0
#   begin
#     i += 1
#     break if i > 5
#   end until i > 9
#
#   assert_equal(6, i)
# end

# --- BLOCKED: the do-while form, `begin ... end until`, is excluded
# (U016).
# assert("The until modifier with begin .. end block returns value passed to break if interrupted by break") do
#   assert_equal(123, (begin; break 123; end until false))
# end

# --- BLOCKED: the do-while form, `begin ... end until`, is excluded
# (U016).
# assert("The until modifier with begin .. end block returns nil if interrupted by break with no arguments") do
#   assert_equal(nil, (begin; break; end until false))
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The until modifier with begin .. end block runs block at least once (even if the expression is true)") do
#   i = 0
#   begin
#     i += 1
#   end until true
#
#   assert_equal(1, i)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The until modifier with begin .. end block evaluates condition after block execution") do
#   a = []
#   i = 0
#   begin
#     a << i
#   end until (i+=1)>=5
#   assert_equal([0, 1, 2, 3, 4], a)
# end

# --- BLOCKED: the do-while form, `begin ... end while`, is excluded
# (U016).
# assert("The until modifier with begin .. end block skips to end of body with next") do
#   a = []
#   i = 0
#   begin
#     next if i==3
#     a << i
#   end until (i+=1)>=5
#   assert_equal([0, 1, 2, 4], a)
# end

# --- BLOCKED: the do-while form, `begin ... end until`, is excluded
# (U016).
# assert("The until modifier with begin .. end block restart the current iteration without reevaluating condition with redo") do
#   a = []
#   i = 0
#   j = 0
#   begin
#     a << i
#     j+=1
#     redo if j<3
#   end until (i+=1)>=3
#   assert_equal([0, 0, 0, 1, 2], a)
# end
