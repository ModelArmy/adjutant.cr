# Derived from ruby/spec language/or_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The || operator evaluates to true if any of its operands are true") do
  if false || true || nil
    x = true
  end
  assert_equal(true, x)
end

assert("The || operator evaluated to false if all of its operands are false") do
  if false || nil
    x = true
  end
  assert_equal(nil, x)
end

assert("The || operator is evaluated before assignment operators") do
  x = nil || true
  assert_equal(true, x)
end

assert("The || operator has a lower precedence than the && operator") do
  x = 1 || false && x = 2
  assert_equal(1, x)
end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The || operator treats empty expressions as nil") do
#   assert_equal(true, (() || true))
#   assert_equal(false, (() || false))
#   assert_equal(true, (true || ()))
#   assert_equal(nil, (false || ()))
#   assert_equal(nil, (() || ()))
# end

assert("The || operator has a higher precedence than 'break' in 'break true || false'") do
  # see also 'break true or false' below
  assert_equal(true, -> { break false || true }.call)
end

assert("The || operator has a higher precedence than 'next' in 'next true || false'") do
  assert_equal(true, -> { next false || true }.call)
end

assert("The || operator has a higher precedence than 'return' in 'return true || false'") do
  assert_equal(true, -> { return false || true }.call)
end

assert("The or operator evaluates to true if any of its operands are true") do
  x = nil
  if false or true
    x = true
  end
  assert_equal(true, x)
end

assert("The or operator is evaluated after variables are assigned") do
  x = nil or true
  assert_equal(nil, x)
end

assert("The or operator has a lower precedence than the || operator") do
  x,y = nil
  x = true || false or y = 1
  assert_equal(nil, y)
end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The or operator treats empty expressions as nil") do
#   assert_equal(true, (() or true))
#   assert_equal(false, (() or false))
#   assert_equal(true, (true or ()))
#   assert_equal(nil, (false or ()))
#   assert_equal(nil, (() or ()))
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The or operator has a lower precedence than 'break' in 'break true or false'") do
#   # see also 'break true || false' above
#   -> { eval "break true or false" }.should.raise(SyntaxError, /void value expression/)
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The or operator has a lower precedence than 'next' in 'next true or false'") do
#   -> { eval "next true or false" }.should.raise(SyntaxError, /void value expression/)
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The or operator has a lower precedence than 'return' in 'return true or false'") do
#   -> { eval "return true or false" }.should.raise(SyntaxError, /void value expression/)
# end
