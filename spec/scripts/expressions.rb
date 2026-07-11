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
  class A
    def self.x; 6; end
  end

  A.x == 6
end

assert "Class ivar initialization" do
  class A
    @x = 6
    def self.x; @x; end
  end

  A.x == 6
end

assert "Class ivar and cvars" do
  class A
    @x = 6
    def self.x; @x; end
    def initialize; @x=2; @@x=7; end
    def x; @x; end
    def aax; @@x; end
    def self.aax; @@x; end
  end

  (A.x == 6) && (A.new.x == 2) && (A.aax == 7) && (A.aax == A.new.aax)
end

assert "Object built-in methods" do
  class A
  end

  module M
    class B
    end
  end

  assert_not_nil(A.new.class)
  assert_not_nil(A.class)

  assert_not_nil(M::B.new.class)
  assert_not_nil(M::B.class)

  assert_not_nil(M.class)

  x = A.new
  x.is_a? A
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
