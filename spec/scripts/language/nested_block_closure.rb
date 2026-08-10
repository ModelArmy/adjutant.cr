require "assert"

# Case 1: single-level block — a block reading a variable from its
# IMMEDIATE enclosing method (one hop). Should already work today.
def single_level_block
  x = 10
  result = nil
  [1].each do |i|
    result = x + 1
  end
  result
end
assert_equal 11, single_level_block

# # Case 2: two-level block nesting — the INNER block (nested inside the
# # OUTER block, which is itself inside the method that owns x) reads x
# # two scopes up. No lambda/proc involved at all here — this isolates
# # whether the gap is specific to Op::MakeProc's lambda-capture path,
# # or the more general block outer-scope mechanism itself.
# def two_level_block
#   x = 10
#   result = nil
#   [1].each do |i|
#     [1].each do |j|
#       result = x + 1
#     end
#   end
#   result
# end
# assert_equal 11, two_level_block

# # Case 3: three-level block nesting, same shape, one hop further —
# # useful if case 2 actually passes and case 3 doesn't, which would
# # narrow the gap to "more than N hops" rather than "more than one."
# def three_level_block
#   x = 10
#   result = nil
#   [1].each do |i|
#     [1].each do |j|
#       [1].each do |k|
#         result = x + 1
#       end
#     end
#   end
#   result
# end
# assert_equal 11, three_level_block

# # Case 4: same shape as case 2, but WRITING to x instead of reading it.
# def two_level_block_write
#   x = 10
#   [1].each do |i|
#     [1].each do |j|
#       x = 99
#     end
#   end
#   x
# end
# assert_equal 99, two_level_block_write
