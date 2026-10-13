# Derived from ruby/spec language/unless_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The unless expression evaluates the unless body when the expression is false") do
  unless false
    a = true
  else
    a = false
  end

  assert_equal(true, a)
end

assert("The unless expression returns the last statement in the body") do
  result = unless false
    'foo'
    'bar'
    'baz'
  end
  assert_equal('baz', result)
end

assert("The unless expression evaluates the else body when the expression is true") do
  result = unless true
    'foo'
  else
    'bar'
  end
  assert_equal('bar', result)
end

# --- BLOCKED: `then` after an `unless` condition doesn't parse
# (SCOPE.md, Parser / lexer gaps).
# assert("The unless expression takes an optional then after the expression") do
#   result = unless false then
#     'baz'
#   end
#   assert_equal('baz', result)
# end

assert("The unless expression does not return a value when the expression is true") do
  assert_equal(nil, unless true; end)
end

# --- BLOCKED: `then` after an `unless` condition doesn't parse
# (SCOPE.md, Parser / lexer gaps).
# assert("The unless expression allows expression and body to be on one line (using 'then')") do
#   assert_equal('foo', unless false then 'foo'; else 'bar'; end)
# end
