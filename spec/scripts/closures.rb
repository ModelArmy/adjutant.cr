require "assert"

assert("method locals do not leak to global scope") {
  x = 1
  def set_x
    x = 99
  end
  set_x
  x == 1
}

assert("a bare identifier that is a def is called, not just referenced") {
  def answer
    42
  end
  answer == 42
}

assert("block captures local from its defining scope via yield") {
  total = 0
  def apply
    yield 1
    yield 2
    yield 3
  end
  apply { |x| total += x }
  total == 6
}
