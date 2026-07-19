require "assert"

# ---- TODO: Expression and assignment precedence issue (works in Ruby)
# assert "Assignment as expression" do
#   def sum(a,b); a+b; end

#   7 == tot = sum(3, 4)
# end
# ----

# ---- TODO: support assignment in parens
# assert "Assignment as expression in parens" do
#   def sum(a,b); a+b; end
#   (tot = sum 3, 4) == 7
# end
# ----

# ---- TODO: support chained assignments in a statement
# assert "Chained assignments" do
#   c = b = 5
#   c == 5
# end
# ----

assert "Self reference" do
  class A
    def initialize; @x = 5; end
    def x; @x; end
    def plus(n); self.x + n; end
  end

  a = A.new
  a.plus(3) == 8
end

assert "Class method" do
  class A1
    def self.x; 6; end
  end

  A1.x == 6
end

assert "Class ivar initialization" do
  class A2
    @x = 6
    def self.x; @x; end
  end

  A2.x == 6
end

assert "Class ivar and cvars" do
  class A3
    @x = 6
    def self.x; @x; end
    def initialize; @x=2; @@x=7; end
    def x; @x; end
    def aax; @@x; end
    def self.aax; @@x; end
  end

  (A3.x == 6) && (A3.new.x == 2) && (A3.aax == 7) && (A3.aax == A3.new.aax)
end

assert "Object built-in methods" do
  class A4
  end

  module M
    class B
    end
  end

  assert_not_nil(A4.new.class)
  assert_not_nil(A4.class)

  assert_not_nil(M::B.new.class)
  assert_not_nil(M::B.class)

  assert_not_nil(M.class)

  x = A4.new
  x.is_a? A4
end

# ---- TODO: support special constants
# assert_not_nil(__FILE__)
# assert_not_nil(__LINE__)
# assert_not_nil(__method__)
# assert_not_nil(__callee__)
# ----

assert_not_nil(Class)
assert_not_nil(Object)
assert_not_nil(Module)

assert("Arrays") do
  nums = [5, 10]
  assert_equal nums[0], 5
  nums.each do | n |
    assert_equal n.class, Integer
  end

  strs = ["hello", "world"]
  assert_equal strs[1], "world"

  mixed = ["hello", 5, "world", 0.5432]
  assert_equal mixed[2], "world"

  assert_equal Array, nums.class
end

assert("Strings") do
  str = "Hello"
  assert_equal str[1], "e"
  assert_equal str.upcase, "HELLO"
  assert_equal str.downcase, "hello"
  assert_false str.empty?

  assert_equal String, str.class
end

assert("Hashmaps") do
  letters = {"a" => 1, "b" => 2, "z" => 26}
  assert_equal letters.size, 3

  letters.keys.each do | k |
    assert_equal k.class, String
  end

  letters.values.each do | v |
    assert_equal v.class, Integer
  end

  letters.each do | k, v |
    assert_equal letters[k], v
  end
end

assert("Ranges") do
  a = 0..3
  assert_not_nil a
  assert_equal a.class, Range
  assert_equal a.min, 0
  assert_equal a.max, 3
  assert_equal a.exclusive?, false

  b = 0...3
  assert_not_nil b
  assert_equal b.class, Range
  assert_equal b.exclusive?, true

  total = 0
  for x in 1..4
    total += x
  end
  assert_equal total, 10 # inclusive: 1+2+3+4

  total2 = 0
  for x in 1...4
    total2 += x
  end
  assert_equal total2, 6 # exclusive: 1+2+3

  seen = []
  (1..3).each do |n|
    seen << n
  end
  assert_equal seen, [1, 2, 3]

  r = 1..5
  re = 1...5
  assert_equal r.include?(3), true
  assert_equal r.include?(5), true
  assert_equal re.include?(5), false
  assert_equal r.include?(0), false
end

assert "in-script methods" do
  def test
    10
  end

  # Script-defined method
  assert_not_equal test.class, NilClass

  x = assert "test" do
    true
  end

  assert_not_equal x.class, NilClass
end

assert "unknown var should raise" do
  assert_raise NameError do
    unknown
  end
end

assert "known native global" do
  assert_not_nil version
  assert_equal version.class, String
end

assert "class names should include namespace unless root" do
  module A5
    class B
    end
  end
  class C
  end

  b = A5::B.new
  c = C.new

  assert_equal b.class.to_s, "A5::B"
  assert_equal c.class.to_s, "C"
end

assert "lambdas" do
  def callback(fun, val)
    fun(val)
  end

  dbl = ->(n) { n + n }
  assert_equal dbl.call(3), 6

  y = dbl
  assert_equal y.class, Proc
end

assert "lambdas in module" do
  module M2
    dbl = ->(n) { n + n }
    assert_not_nil dbl

    def self.x; end

    assert_not_nil(x)
  end

  assert_equal dbl.call(3), 6
  true
end

assert "self as param in no-paren method call" do
  module M3
  assert_not_equal self, nil
  end
  assert_not_equal self, nil
end

assert "test calls in array vs not" do
  sq = ->(x) { x * x }
  a = sq.call(2)
  b = sq.call(3)
  c = sq.call(4)
  assert_equal 4, a
  assert_equal 9, b
  assert_equal 16, c

  ar = [sq.call(2), sq.call(3), sq.call(4)]
  assert_equal a, ar[0]
  assert_equal b, ar[1]
  assert_equal c, ar[2]
 end

assert "arrays as no-paren params to method call" do
  ar = [3, 9, 16]
  assert_equal([3, 9, 16], ar)  # OK
  assert_equal ar, [3, 9, 16]   # OK

  # --- FIX parser bug
  # assert_equal [3, 9, 16], ar   # does not parse
  # ---
end

assert "Monkey-patching not supported" do
  assert_raise RuntimeError do
    class String
      def hello; "hello"; end
    end
  end
end
