# Derived from ruby/spec language/redo_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The redo statement restarts block execution if used within block") do
  a = []
  -> {
    a << 1
    if a.size < 2
      redo
    end
    a << 2
  }.call
  assert_equal([1, 1, 2], a)
end

# --- BLOCKED: `Array#delete` doesn't exist (SCOPE.md, Standard library
# surface).
# assert("The redo statement re-executes the closest loop") do
#   exist = [2,3]
#   processed = []
#   order = []
#   [1,2,3,4].each do |x|
#     order << x
#     begin
#       processed << x
#       if exist.include?(x)
#         raise StandardError, "included"
#       end
#     rescue StandardError
#       exist.delete(x)
#       redo
#     end
#   end
#   assert_equal([1,2,2,3,3,4], processed)
#   assert_equal([], exist)
#   assert_equal([1,2,2,3,3,4], order)
# end

assert("The redo statement re-executes the last step in enumeration") do
  list = []
  [1,2,3].each do |x|
    list << x
    break if list.size == 6
    if x == 3
      redo
    end
  end
  assert_equal([1,2,3,3,3,3], list)
end

# --- BLOCKED: `Array#count` doesn't exist (SCOPE.md, Data & builtin
# types).
# assert("The redo statement triggers ensure block when re-executing a block") do
#   list = []
#   [1,2,3].each do |x|
#     list << x
#     begin
#       list << 10*x
#       if list.count(1) == 1
#         redo
#       end
#     ensure
#       list << 100*x
#     end
#   end
#   assert_equal([1,10,100,1,10,100,2,20,200,3,30,300], list)
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The redo statement in a method is invalid and raises a SyntaxError") do
#   assert_raise(SyntaxError) {
#     eval("def m; redo; end")
#   }
# end
