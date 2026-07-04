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

# ---- TODO: support multiple assignments in a statement
# assert "Multiple assignments" do
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

# ---- TODO: class ivar init
# assert "Class ivar initialization" do
#   class A
#     @x = 6
#     def self.x; @x; end
#   end

#   A.x == 6
# end
# ----

# ---- TODO: class method on objects
# assert "Object built-in methods" do
#   class A
#   end

#   assert_not_nil(A.new.class)
#   assert_not_nil(A.class)
# end
# ----

# ---- TODO: support special constants
# assert_not_nil(__FILE__)
# assert_not_nil(__LINE__)
# assert_not_nil(__method__)
# assert_not_nil(__callee__)
# ----

# ---- TODO: support base classes / object constants
# assert_not_nil(Class)
# assert_not_nil(Object)
# assert_not_nil(BasicObject)
# ----
