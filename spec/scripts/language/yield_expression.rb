require "assert"

def doubled
  x = yield 10
  x + 1
end
assert_equal 21, doubled { |n| n * 2 }

def shout
  yield.upcase
end
assert_equal "HI", shout { "hi" }

def plus_four
  yield + 4
end
assert_equal 14, plus_four { 10 }

def collect_three
  [yield(1), yield(2), yield(3)]
end
assert_equal [2, 4, 6], collect_three { |n| n * 2 }

def attempt(n)
  attempt = 0
  while attempt < n
    attempt = attempt + 1
    begin
      return yield
    rescue e
      raise e if attempt >= n
    end
  end
end
calls = 0
result = attempt(3) do
  calls = calls + 1
  raise "not yet" if calls < 3
  "ok"
end
assert_equal "ok", result
assert_equal 3, calls

def no_block
  yield
end
assert_raise { no_block }

def keep_lines(lines)
  kept = []
  lines.each { |line| kept << line if yield(line) }
  kept
end
assert_equal ["alpha", "gamma"], keep_lines(["alpha", "bee", "gamma"]) { |l| l.length > 3 }

def sum_cells(rows)
  sum = 0
  rows.each do |row|
    row.each do |cell|
      sum = sum + yield(cell)
    end
  end
  sum
end
assert_equal 60, sum_cells([[1, 2], [3]]) { |n| n * 10 }

def run_twice
  yield
  yield
end
def collect_from_outer
  results = []
  run_twice { results << yield }
  results
end
assert_equal ["outer", "outer"], collect_from_outer { "outer" }
