a = 0
b = 1
i = 0
while i < 10
  tmp = a + b
  a = b
  b = tmp
  i += 1
end

assert_equal(a, 55)
a
