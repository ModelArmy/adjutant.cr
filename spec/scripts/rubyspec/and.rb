# Derived from ruby/spec language/and_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The '&&' statement short-circuits evaluation at the first condition to be false") do
  x = nil
  true && false && x = 1
  assert_equal(nil, x)
end

assert("The '&&' statement evaluates to the first condition not to be true") do
  value = nil
  assert_equal(nil, (value && nil))
  assert_equal(nil, (value && false))
  value = false
  assert_equal(false, (value && nil))
  assert_equal(false, (value && false))

  assert_equal(nil, ("yes" && 1 && nil && true))
  assert_equal(false, ("yes" && 1 && false && true))
end

assert("The '&&' statement evaluates to the last condition if all are true") do
  assert_equal(1, ("yes" && 1))
  assert_equal("yes", (1 && "yes"))
end

assert("The '&&' statement evaluates the full set of chained conditions during assignment") do
  x, y = nil
  x = 1 && y = 2
  # "1 && y = 2" is evaluated and then assigned to x
  assert_equal(2, x)
end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The '&&' statement treats empty expressions as nil") do
#   assert_equal(nil, (() && true))
#   assert_equal(nil, (true && ()))
#   assert_equal(nil, (() && ()))
# end

assert("The 'and' statement short-circuits evaluation at the first condition to be false") do
  x = nil
  true and false and x = 1
  assert_equal(nil, x)
end

assert("The 'and' statement evaluates to the first condition not to be true") do
  value = nil
  assert_equal(nil, (value and nil))
  assert_equal(nil, (value and false))
  value = false
  assert_equal(false, (value and nil))
  assert_equal(false, (value and false))

  assert_equal(nil, ("yes" and 1 and nil and true))
  assert_equal(false, ("yes" and 1 and false and true))
end

assert("The 'and' statement evaluates to the last condition if all are true") do
  assert_equal(1, ("yes" and 1))
  assert_equal("yes", (1 and "yes"))
end

assert("The 'and' statement when used in assignment, evaluates and assigns expressions individually") do
  x, y = nil
  x = 1 and y = 2
  # evaluates (x=1) and (y=2)
  assert_equal(1, x)
end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The 'and' statement treats empty expressions as nil") do
#   assert_equal(nil, (() and true))
#   assert_equal(nil, (true and ()))
#   assert_equal(nil, (() and ()))
# end
