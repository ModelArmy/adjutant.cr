# Derived from ruby/spec language/loop_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The loop expression repeats the given block until a break is called") do
  outer_loop = 0
  loop do
    outer_loop += 1
    break if outer_loop == 10
  end
  assert_equal(10, outer_loop)
end

# --- BLOCKED: `loop`'s body shares the enclosing scope (SCOPE.md, Must
# Fix).
# assert("The loop expression executes code in its own scope") do
#   loop do
#     inner_loop = 123
#     break
#   end
#   assert_raise(NameError) { inner_loop }
# end

# --- BLOCKED: `loop` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The loop expression returns the value passed to break if interrupted by break") do
#   result = loop do
#     break 123
#   end
#   assert_equal(123, result)
# end

# --- BLOCKED: `loop` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("The loop expression returns nil if interrupted by break with no arguments") do
#   result = loop do
#     break
#   end
#   assert_equal(nil, result)
# end

assert("The loop expression skips to end of body with next") do
  a = []
  i = 0
  loop do
    break if (i+=1) >= 5
    next if i == 3
    a << i
  end
  assert_equal([1, 2, 4], a)
end

assert("The loop expression restarts the current iteration with redo") do
  a = []
  loop do
    a << 1
    if a.size < 2
      redo
    end
    a << 2
    break if a.size == 3
  end
  assert_equal([1, 1, 2], a)
end

assert("The loop expression uses a spaghetti nightmare of redo, next and break") do
  a = []
  loop do
    a << 1
    if a.size == 1
      redo
    end
    a << 2
    next if a.size == 3
    a << 3
    break if a.size > 6
  end
  assert_equal([1, 1, 2, 1, 2, 3, 1, 2, 3], a)
end
