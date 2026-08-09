require "assert"

# `dup`/`clone` — SCOPE.md Must Fix item, promoted 2026-08-05, fixed
# 2026-08-08 for RubyObject receivers. Both allocate a fresh instance
# of the same class and shallow-copy `ivars`; `initialize` is never
# re-run. A class-defined `initialize_copy` runs afterward if present,
# receiving the original as its argument and `self` bound to the copy.
#
# Adjutant doesn't model frozen state, so `dup` and `clone` behave
# identically here — real Ruby's only distinction between them
# (clone preserves frozen-ness) has nothing to attach to yet.
#
# Builtin-kind receivers (Integer, String, Array, Hash, ...) are
# deliberately out of scope — see SCOPE.md's "Data & builtin types"
# entry — and still raise NoMethodError.

class Point
  attr_accessor :x, :y

  def initialize(x, y)
    @x = x
    @y = y
  end
end

assert("dup copies ivars into a new instance of the same class") do
  original = Point.new(1, 2)
  copy = original.dup
  copy.class == Point && copy.x == 1 && copy.y == 2
end

assert("dup's copy is independent of the original") do
  original = Point.new(1, 2)
  copy = original.dup
  copy.x = 99
  original.x == 1 && copy.x == 99
end

assert("clone behaves the same as dup here") do
  original = Point.new(3, 4)
  copy = original.clone
  copy.class == Point && copy.x == 3 && copy.y == 4
end

assert("dup does not re-run initialize") do
  class Counter
    @@count = 0

    def initialize
      @@count += 1
    end

    def self.count
      @@count
    end
  end

  Counter.new
  before = Counter.count
  Counter.new.dup
  # One .new (already counted in `before`) plus one more .new, but
  # the .dup on that second instance must NOT trigger a third
  # initialize call.
  Counter.count == before + 1
end

assert("a class-defined initialize_copy runs on dup, original as arg") do
  class Wrapper
    attr_accessor :tag

    def initialize(tag)
      @tag = tag
    end

    def initialize_copy(original)
      @tag = "copy of #{original.tag}"
    end
  end

  original = Wrapper.new("first")
  copy = original.dup
  copy.tag == "copy of first" && original.tag == "first"
end

assert("dup/clone on a builtin-kind receiver still raises (out of scope)") do
  assert_raise { 5.dup }
  assert_raise { "hello".dup }
  assert_raise { [1, 2].dup }
end
