require "assert"

source = (Legate::Path.new(__FILE__).parent / "fixtures" / "report.txt").to_s

copy = backup(source)
assert("returns a String") { copy.is_a?(String) }
assert_true(copy.end_with?(".bak"))
assert_equal(Legate.read(source), Legate.read(copy))
assert_nothing_raised { backup(source) }
assert_equal(Legate.read(source), Legate.read(copy))
