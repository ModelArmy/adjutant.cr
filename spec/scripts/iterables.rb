require "assert"

assert "each do with arrays" do
  a = [1, 3, 5, 7, 9]
  a.each do |o|
    assert_equal o.class, Integer
  end
end

assert "for loop with 'do'" do
  a = [1, 3, 5, 7, 9]
  for o in a do
    assert_equal o.class, Integer
  end
end

assert "for loop without 'do'" do
  a = [1, 3, 5, 7, 9]
  for o in a
    assert_equal o.class, Integer
  end
end

assert "for loop over a Range with 'do'" do
  total = 0
  for o in 1..4 do
    assert_equal o.class, Integer
    total += o
  end
  assert_equal total, 10
end

assert "for loop over a Range without 'do'" do
  total = 0
  for o in 1..4
    total += o
  end
  assert_equal total, 10
end

assert "for loop over an exclusive Range" do
  total = 0
  for o in 1...4
    total += o
  end
  assert_equal total, 6
end

assert "while loop with 'do'" do
  a = [1, 3, 5, 7, 9]
  i = 0
  while i < a.size do
    o = a[i]
    i += 1
    assert_equal o.class, Integer
  end
  true

end

assert "while loop without 'do'" do
  a = [1, 3, 5, 7, 9]
  i = 0
  while i < a.size
    o = a[i]
    i += 1
    assert_equal o.class, Integer
  end
  true
end

assert "until loop with 'do'" do
  a = [1, 3, 5, 7, 9]
  i = 0
  until i >= a.size do
    o = a[i]
    i += 1
    assert_equal o.class, Integer
  end
  true
end

assert "until loop without 'do'" do
  a = [1, 3, 5, 7, 9]
  i = 0
  until i >= a.size
    o = a[i]
    i += 1
    assert_equal o.class, Integer
  end
  true
end

assert "while returns nil" do
  assert_nil do
    i = 0
    while i < 3
      i+= 1
    end
  end
end
