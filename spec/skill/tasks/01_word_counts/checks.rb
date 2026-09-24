require "assert"

counts = word_counts(Legate::Path.new(__FILE__).parent / "fixtures" / "text.txt")

assert("returns a Hash") { counts.is_a?(Hash) }
assert_equal(3, counts["the"])
assert_equal(1, counts["fox"])
assert_equal(1, counts["dog."])
assert_equal(1, counts["end"])
assert_nil(counts["THE"])
assert_equal(8, counts.size)
