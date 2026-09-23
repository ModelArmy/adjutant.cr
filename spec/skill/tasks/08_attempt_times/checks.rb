require "assert"

calls = 0
flaky = -> {
  calls = calls + 1
  raise "not yet" if calls < 3
  "ok"
}
assert_equal("ok", attempt_times(3, flaky))
assert_equal(3, calls)

once = 0
steady = -> {
  once = once + 1
  "first"
}
assert_equal("first", attempt_times(2, steady))
assert_equal(1, once)

attempts = 0
always = -> {
  attempts = attempts + 1
  raise "always"
}
assert_raise { attempt_times(2, always) }
assert_equal(2, attempts)
