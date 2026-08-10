require "assert"

# Case 1: single-level closure — a lambda created directly inside the
# method that owns the variable ("one hop"). Should already work today.
def single_level
  x = 10
  make_inc = -> { x + 1 }
  make_inc.call
end
assert_equal 11, single_level

# # Case 2: two-level closure — a lambda created INSIDE A BLOCK, which is
# # itself inside the method that owns the variable. The lambda never
# # declares or receives x itself; it only reads it from two scopes up
# # (method -> block -> lambda).
# def two_level
#   x = 10
#   result = nil
#   [1].each do |i|
#     inc = -> { x + 1 }
#     result = inc.call
#   end
#   result
# end
# assert_equal 11, two_level

# # Case 3: same shape as case 2, but WRITING to x instead of reading it —
# # checks whether the same gap affects assignment, not just reads.
# def two_level_write
#   x = 10
#   [1].each do |i|
#     setter = -> { x = 99 }
#     setter.call
#   end
#   x
# end
# assert_equal 99, two_level_write
