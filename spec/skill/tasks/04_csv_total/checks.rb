require "assert"

path = Legate::Path.new(__FILE__).parent / "fixtures" / "stock.csv"

assert_equal(20, csv_total(path, "qty"))
assert_equal(220, csv_total(path, "price"))
assert("returns an Integer") { csv_total(path, "qty").is_a?(Integer) }
