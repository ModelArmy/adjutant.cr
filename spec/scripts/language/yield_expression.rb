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
