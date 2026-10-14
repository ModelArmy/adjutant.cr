# Derived from ruby/spec language/not_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The not keyword negates a `true' value") do
  assert_equal(false, (not true))
  assert_equal(false, (not 'true'))
end

assert("The not keyword negates a `false' value") do
  assert_equal(true, (not false))
  assert_equal(true, (not nil))
end

assert("The not keyword accepts an argument") do
  assert_equal(false, not(true))
end

assert("The not keyword returns false if the argument is true") do
  assert_equal(false, (not(true)))
end

assert("The not keyword returns true if the argument is false") do
  assert_equal(true, (not(false)))
end

assert("The not keyword returns true if the argument is nil") do
  assert_equal(true, (not(nil)))
end

assert("The `!' keyword negates a `true' value") do
  assert_equal(false, (!true))
  assert_equal(false, (!'true'))
end

assert("The `!' keyword negates a `false' value") do
  assert_equal(true, (!false))
  assert_equal(true, (!nil))
end

assert("The `!' keyword doubled turns a truthful object into `true'") do
  assert_equal(true, (!!true))
  assert_equal(true, (!!'true'))
end

assert("The `!' keyword doubled turns a not truthful object into `false'") do
  assert_equal(false, (!!false))
  assert_equal(false, (!!nil))
end
