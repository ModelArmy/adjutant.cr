require "assert"

path = Legate::Path.new(__FILE__).parent / "fixtures" / "words.txt"

assert_equal(["a", "b", "c"], top_words(path, 3))
assert_equal(["a"], top_words(path, 1))
assert_equal(["a", "b"], top_words(path, 2))
assert_equal(["a", "b", "c", "d", "e"], top_words(path, 10))
