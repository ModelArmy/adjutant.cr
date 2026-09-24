require "assert"

stats = line_stats(Legate::Path.new(__FILE__).parent / "fixtures" / "big.txt")

assert("returns a Hash") { stats.is_a?(Hash) }
assert_equal(300, stats[:lines])
assert_equal(80, stats[:longest])
