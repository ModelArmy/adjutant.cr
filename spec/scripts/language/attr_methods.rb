require "assert"

# `attr_reader`/`attr_writer`/`attr_accessor` — found 2026-08-08 as a
# real gap while writing dup_clone.rb (a lexer keyword token existed
# for all three, `token.cr`, but the parser had no handling at all —
# `attr_accessor :x, :y` raised P002, "can't start an expression
# here"). Fixed the same session: `Parser#parse_attr` desugars each at
# PARSE time into the same DefNode shape a hand-written `def x; @x;
# end` would produce — see that method's own comment in parser.cr for
# why the multi-def desugar needed a matching fix in how statement
# lists get built (`append_statement`), not just in parse_attr itself.

class Reader
  attr_reader :value

  def initialize(value)
    @value = value
  end
end

assert("attr_reader defines a getter that reads the ivar") do
  Reader.new(42).value == 42
end

assert("attr_reader does NOT define a setter") do
  assert_raise { Reader.new(1).value = 2 }
end

class Writer
  attr_writer :value

  def initialize
    @value = nil
  end

  def peek
    @value
  end
end

assert("attr_writer defines a setter that writes the ivar") do
  w = Writer.new
  w.value = 7
  w.peek == 7
end

assert("attr_writer does NOT define a getter") do
  assert_raise { Writer.new.value }
end

class Accessor
  attr_accessor :x, :y

  def initialize(x, y)
    @x = x
    @y = y
  end
end

assert("attr_accessor defines both a getter and setter, for every name given") do
  a = Accessor.new(1, 2)
  a.x == 1 && a.y == 2
end

assert("attr_accessor's setters are independently writable") do
  a = Accessor.new(1, 2)
  a.x = 10
  a.y = 20
  a.x == 10 && a.y == 20
end

class Parenthesized
  attr_accessor(:label)

  def initialize(label)
    @label = label
  end
end

assert("attr_accessor accepts optional parens, same as a real method call") do
  Parenthesized.new("tag").label == "tag"
end

assert("a class can combine attr_accessor with its own ordinary methods") do
  class Combined
    attr_accessor :count

    def initialize
      @count = 0
    end

    def increment
      @count += 1
    end
  end

  c = Combined.new
  c.increment
  c.increment
  c.count == 2
end
