require "assert"

##
# Object ISO Test

assert('Object', '15.2.1') do
  assert_equal Class, Object.class
end

#
# --- WONTFIX: No plan to support BasicObject
# assert('Object superclass', '15.2.1.2') do
#   assert_equal BasicObject, Object.superclass
# end
#
assert("Object superclass is nil") do
  assert_nil Object.superclass
end
# ---
