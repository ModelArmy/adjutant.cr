require "assert"

path = Legate::Path.new(__FILE__).parent / "fixtures" / "words.txt"

assert_equal(["alpha", "gamma", "delta"], keep_lines(path) { |line| line.length > 3 })
assert_equal([], keep_lines(path) { |line| false })

seen = 0
keep_lines(path) do |line|
  seen = seen + 1
  true
end
assert_equal(5, seen)
