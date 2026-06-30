require "assert"

assert("integer addition") { 1 + 2 == 3 }
assert("integer subtraction") { 5 - 3 == 2 }
assert("integer multiplication") { 3 * 4 == 12 }
assert("integer division floors") { 7 / 2 == 3 }
assert("modulo") { 7 % 3 == 1 }
assert("float addition") { 1.5 + 2.5 == 4.0 }
assert("int and float promote to float") { (1 + 2.5) == 3.5 }
assert("negation") { -7 == 0 - 7 }
assert("string concatenation") { ("hello" + " world") == "hello world" }

assert_equal(3, 1 + 2)
assert_equal(2, 5 - 3)
assert_equal(12, 3 * 4)
assert_equal(1, 7 % 3)
assert_not_equal(1, 2)

assert("comparison: less than") { 1 < 2 }
assert("comparison: greater than") { 3 > 2 }
assert("comparison: less or equal") { 2 <= 2 }
assert("comparison: greater or equal") { 2 >= 2 }
assert("equality") { 1 == 1 }
assert("inequality") { 1 != 2 }

assert("boolean and") { (true && true) == true }
assert("boolean and short circuits") { (false && true) == false }
assert("boolean or") { (false || true) == true }
assert("negation operator") { !false == true }

assert_true(true)
assert_false(false)
assert_nil(nil)
assert_not_nil(1)
