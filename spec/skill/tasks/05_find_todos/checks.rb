require "assert"

glob = (Legate::Path.new(__FILE__).parent / "fixtures" / "*.txt").to_s

assert_equal(["one.txt:2", "two.txt:3"], find_todos(glob))
