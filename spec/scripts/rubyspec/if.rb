# Derived from ruby/spec language/if_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

# --- BLOCKED: a multiple assignment inside parentheses doesn't parse
# (SCOPE.md, Parser / lexer gaps: parentheses hold exactly one
# expression).
# assert("The if expression accepts multiple assignments in conditional expression with non-nil values") do
#   recorded = nil
#   ary = [1, 2]
#   if (a, b = ary); recorded = [a, b]; end
#   assert_equal([1, 2], recorded)
# end
#
# assert("The if expression accepts multiple assignments in conditional expression with nil values") do
#   recorded = nil
#   ary = nil
#   if (a, b = ary); else; recorded = [a, b]; end
#   assert_equal([nil, nil], recorded)
# end

assert("The if expression evaluates body if expression is true") do
  a = []
  if true
    a << 123
  end
  assert_equal([123], a)
end

assert("The if expression does not evaluate body if expression is false") do
  a = []
  if false
    a << 123
  end
  assert_equal([], a)
end

# --- BLOCKED: `()` doesn't parse (SCOPE.md, Parser / lexer gaps:
# parentheses hold exactly one expression).
# assert("The if expression does not evaluate body if expression is empty") do
#   a = []
#   if ()
#     a << 123
#   end
#   assert_equal([], a)
# end

assert("The if expression does not evaluate else-body if expression is true") do
  a = []
  if true
    a << 123
  else
    a << 456
  end
  assert_equal([123], a)
end

assert("The if expression evaluates only else-body if expression is false") do
  a = []
  if false
    a << 123
  else
    a << 456
  end
  assert_equal([456], a)
end

assert("The if expression returns result of then-body evaluation if expression is true") do
  result = if true
    123
  end
  assert_equal(123, result)
end

assert("The if expression returns result of last statement in then-body if expression is true") do
  result = if true
    'foo'
    'bar'
    'baz'
  end
  assert_equal('baz', result)
end

assert("The if expression returns result of then-body evaluation if expression is true and else part is present") do
  result = if true
    123
  else
    456
  end
  assert_equal(123, result)
end

assert("The if expression returns result of else-body evaluation if expression is false") do
  result = if false
    123
  else
    456
  end
  assert_equal(456, result)
end

assert("The if expression returns nil if then-body is empty and expression is true") do
  result = if true
  end
  assert_nil(result)
end

assert("The if expression returns nil if then-body is empty, expression is true and else part is present") do
  result = if true
  else
    456
  end
  assert_nil(result)
end

assert("The if expression returns nil if then-body is empty, expression is true and else part is empty") do
  result = if true
  else
  end
  assert_nil(result)
end

assert("The if expression returns nil if else-body is empty and expression is false") do
  result = if false
    123
  else
  end
  assert_nil(result)
end

assert("The if expression returns nil if else-body is empty, expression is false and then-body is empty") do
  result = if false
  else
  end
  assert_nil(result)
end

assert("The if expression considers an expression with nil result as false") do
  result = if nil
    123
  else
    456
  end
  assert_equal(456, result)
end

assert("The if expression considers a non-nil and non-boolean object in expression result as true") do
  result = if Object.new
    123
  else
    456
  end
  assert_equal(123, result)
end

assert("The if expression considers a zero integer in expression result as true") do
  result = if 0
    123
  else
    456
  end
  assert_equal(123, result)
end

assert("The if expression allows starting else-body on the same line") do
  result = if false
    123
  else 456
  end
  assert_equal(456, result)
end

assert("The if expression evaluates subsequent elsif statements and execute body of first matching") do
  result = if false
    123
  elsif false
    234
  elsif true
    345
  elsif true
    456
  end
  assert_equal(345, result)
end

assert("The if expression evaluates else-body if no if/elsif statements match") do
  result = if false
    123
  elsif false
    234
  elsif false
    345
  else
    456
  end
  assert_equal(456, result)
end

# --- BLOCKED: `then` after an `if` condition doesn't parse (SCOPE.md,
# Parser / lexer gaps).
# assert("The if expression allows 'then' after expression when then-body is on the next line") do
#   result = if true then
#     123
#   end
#   assert_equal(123, result)
#   assert_equal(123, (if true then ; 123; end))
# end
#
# assert("The if expression allows then-body on the same line separated with 'then'") do
#   result = if true then 123
#   end
#   assert_equal(123, result)
#   assert_equal(123, (if true then 123; end))
# end
#
# assert("The if expression returns nil when then-body on the same line separated with 'then' and expression is false") do
#   result = if false then 123
#   end
#   assert_nil(result)
#   assert_nil((if false then 123; end))
# end
#
# assert("The if expression returns nil when then-body separated by 'then' is empty and expression is true") do
#   result = if true then
#   end
#   assert_nil(result)
#   assert_nil((if true then ; end))
# end
#
# assert("The if expression returns nil when then-body separated by 'then', expression is false and no else part") do
#   result = if false then
#   end
#   assert_nil(result)
#   assert_nil((if false then ; end))
# end
#
# assert("The if expression evaluates then-body when then-body separated by 'then', expression is true and else part is present") do
#   result = if true then 123
#   else 456
#   end
#   assert_equal(123, result)
#   assert_equal(123, (if true then 123; else 456; end))
# end
#
# assert("The if expression evaluates else-body when then-body separated by 'then' and expression is false") do
#   result = if false then 123
#   else 456
#   end
#   assert_equal(456, result)
#   assert_equal(456, (if false then 123; else 456; end))
# end

# --- BLOCKED: flip-flops are excluded (U023).
# assert("The if expression with a boolean range ('flip-flop' operator) mimics an awk conditional with a single-element inclusive-end range") do
#   recorded = []
#   10.times { |i| recorded << i if (i == 4)..(i == 4) }
#   assert_equal([4], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) mimics an awk conditional with a many-element inclusive-end range") do
#   recorded = []
#   10.times { |i| recorded << i if (i == 4)..(i == 7) }
#   assert_equal([4, 5, 6, 7], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) mimics a sed conditional with a zero-element exclusive-end range") do
#   recorded = []
#   10.times { |i| recorded << i if (i == 4)...(i == 4) }
#   assert_equal([4, 5, 6, 7, 8, 9], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) mimics a sed conditional with a many-element exclusive-end range") do
#   recorded = []
#   10.times { |i| recorded << i if (i == 4)...(i == 5) }
#   assert_equal([4, 5], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) allows combining two flip-flops") do
#   recorded = []
#   10.times { |i| recorded << i if (i == 4)...(i == 5) or (i == 7)...(i == 8) }
#   assert_equal([4, 5, 7, 8], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) evaluates the first conditions lazily with inclusive-end range") do
#   recorded = []
#   collector = ->(i) { recorded << i }
#   10.times { |i| i if collector[i]...false }
#   assert_equal([0], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) evaluates the first conditions lazily with exclusive-end range") do
#   recorded = []
#   collector = ->(i) { recorded << i }
#   10.times { |i| i if collector[i]..false }
#   assert_equal([0], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) evaluates the second conditions lazily with inclusive-end range") do
#   recorded = []
#   collector = ->(i) { recorded << i }
#   10.times { |i| i if (i == 4)...collector[i] }
#   assert_equal([5], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) evaluates the second conditions lazily with exclusive-end range") do
#   recorded = []
#   collector = ->(i) { recorded << i }
#   10.times { |i| i if (i == 4)..collector[i] }
#   assert_equal([4], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) scopes state by flip-flop") do
#   recorded = []
#   store_me = ->(i) { recorded << i if (i == 4)..(i == 7) }
#   store_me[1]
#   store_me[4]
#   -> { store_me[1] }.call
#   store_me[7]
#   store_me[5]
#   assert_equal([4, 1, 7], recorded)
# end
#
# assert("The if expression with a boolean range ('flip-flop' operator) keeps flip-flops from interfering") do
#   recorded = []
#   a = ->(i) { recorded << i if (i == 4)..(i == 7) }
#   b = ->(i) { recorded << i if (i == 4)..(i == 7) }
#   6.times { |i| a[i] }
#   6.times { |i| b[i] }
#   assert_equal([4, 5, 4, 5], recorded)
# end

# --- BLOCKED: tests a parse-time warning, which Adjutant doesn't emit,
# and sets `$.` (U011).
# assert("The if expression with a boolean range ('flip-flop' operator) warns when Integer literals are used instead of predicates")

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The if expression when a branch syntactically does not return a value raises SyntaxError if both do not return a value")

assert("The if expression when a branch syntactically does not return a value does not raise SyntaxError if one branch returns a value") do
  def if_spec_return_in_else
    a = if false
      42
    else
      return 1
    end
    a
  end

  def if_spec_return_in_then
    a = if true
      return 1
    else
      42
    end
    a
  end

  assert_equal(1, if_spec_return_in_else)
  assert_equal(1, if_spec_return_in_then)
end

assert("The postfix if form evaluates statement if expression is true") do
  a = []
  a << 123 if true
  assert_equal([123], a)
end

assert("The postfix if form does not evaluate statement if expression is false") do
  a = []
  a << 123 if false
  assert_equal([], a)
end

# --- BLOCKED: a modifier `if` inside parentheses doesn't parse
# (SCOPE.md, Parser / lexer gaps: parentheses hold exactly one
# expression).
# assert("The postfix if form returns result of expression if value is true") do
#   assert_equal(123, (123 if true))
# end

# assert("The postfix if form returns nil if expression is false") do
#   assert_nil((123 if false))
# end

# assert("The postfix if form considers a nil expression as false") do
#   assert_nil((123 if nil))
# end

# assert("The postfix if form considers a non-nil object as true") do
#   assert_equal(123, (123 if Object.new))
# end

assert("The postfix if form evaluates then-body in containing scope") do
  a = 123
  if true
    b = a + 1
  end
  assert_equal(124, b)
end

assert("The postfix if form evaluates else-body in containing scope") do
  a = 123
  if false
    b = a + 1
  else
    b = a + 2
  end
  assert_equal(125, b)
end

assert("The postfix if form evaluates elsif-body in containing scope") do
  a = 123
  if false
    b = a + 1
  elsif false
    b = a + 2
  elsif true
    b = a + 3
  else
    b = a + 4
  end
  assert_equal(126, b)
end
