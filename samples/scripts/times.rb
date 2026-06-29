require "assert"

sum = 0
times(10) do | i |
  sum += i
end

assert_equal(sum, 9+8+7+6+5+4+3+2+1+0)
sum
