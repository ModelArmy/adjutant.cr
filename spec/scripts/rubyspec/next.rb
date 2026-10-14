# Derived from ruby/spec language/next_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

module ScratchPad
  STORE = [nil]

  def self.record(value)
    STORE[0] = value
  end

  def self.recorded
    STORE[0]
  end

  def self.clear
    STORE[0] = nil
  end
end

# Fixture: ruby/spec language/fixtures/next.rb
class NextSpecs
  def self.yielding_method(expected)
    assert_equal(expected, yield)
    :method_return_value
  end

  def self.yielding
    yield
  end

  # The methods below are defined to spec the behavior of the next statement
  # while specifically isolating whether the statement is in an Iter block or
  # not. In a normal spec example, the code is always nested inside a block.
  # Rather than rely on that implicit context in this case, the context is
  # made explicit because of the interaction of next in a loop nested inside
  # an Iter block.
  def self.while_next(arg)
    x = true
    while x
      begin
        ScratchPad.recorded << :begin
        x = false
        if arg
          next 42
        else
          next
        end
      ensure
        ScratchPad.recorded << :ensure
      end
    end
  end

  def self.while_within_iter(arg)
    yielding do
      x = true
      while x
        begin
          ScratchPad.recorded << :begin
          x = false
          if arg
            next 42
          else
            next
          end
        ensure
          ScratchPad.recorded << :ensure
        end
      end
    end
  end

  def self.until_next(arg)
    x = false
    until x
      begin
        ScratchPad.recorded << :begin
        x = true
        if arg
          next 42
        else
          next
        end
      ensure
        ScratchPad.recorded << :ensure
      end
    end
  end

  def self.until_within_iter(arg)
    yielding do
      x = false
      until x
        begin
          ScratchPad.recorded << :begin
          x = true
          if arg
            next 42
          else
            next
          end
        ensure
          ScratchPad.recorded << :ensure
        end
      end
    end
  end

  def self.loop_next(arg)
    x = 1
    loop do
      break if x == 2

      begin
        ScratchPad.recorded << :begin
        x += 1
        if arg
          next 42
        else
          next
        end
      ensure
        ScratchPad.recorded << :ensure
      end
    end
  end

  def self.loop_within_iter(arg)
    yielding do
      x = 1
      loop do
        break if x == 2

        begin
          ScratchPad.recorded << :begin
          x += 1
          if arg
            next 42
          else
            next
          end
        ensure
          ScratchPad.recorded << :ensure
        end
      end
    end
  end

  class Block
    def method(v)
      yield v
    end
  end
end


assert("The next statement from within the block ends block execution") do
  ScratchPad.record([])
  a = []
  -> {
    a << 1
    next
    a << 2
  }.call
  assert_equal([1], a)
end

assert("The next statement from within the block causes block to return nil if invoked without arguments") do
  ScratchPad.record([])
  assert_equal(nil, -> { 123; next; 456 }.call)
end

# --- BLOCKED: parentheses hold exactly one expression, so `()` doesn't
# parse (SCOPE.md, Parser / lexer gaps).
# assert("The next statement from within the block causes block to return nil if invoked with an empty expression") do
#   ScratchPad.record([])
#   assert_equal(nil, -> { next (); 456 }.call)
# end

assert("The next statement from within the block returns the argument passed") do
  ScratchPad.record([])
  assert_equal(234, -> { 123; next 234; 345 }.call)
end

assert("The next statement from within the block returns to the invoking method") do
  ScratchPad.record([])
  assert_equal(:method_return_value, NextSpecs.yielding_method(nil) { next; })
end

# --- BLOCKED: `return`, `break` and `next` take one value (SCOPE.md,
# Parser / lexer gaps).
# assert("The next statement from within the block returns to the invoking method, with the specified value") do
#   ScratchPad.record([])
#   result = NextSpecs.yielding_method(nil) {
#     next nil;
#     fail("next didn't end the block execution")
#   }
#   assert_equal(:method_return_value, result)
#
#   result = NextSpecs.yielding_method(1) {
#     next 1
#     fail("next didn't end the block execution")
#   }
#   assert_equal(:method_return_value, result)
#
#   result = NextSpecs.yielding_method([1, 2, 3]) {
#     next 1, 2, 3
#     fail("next didn't end the block execution")
#   }
#   assert_equal(:method_return_value, result)
# end

# --- BLOCKED: captures or passes a block with `&` (U001).
# assert("The next statement from within the block returns to the currently yielding method in case of chained calls") do
#   ScratchPad.record([])
#   class ChainedNextTest
#     def self.meth_with_yield(&b)
#       assert_equal(:next_return_value, yield)
#       :method_return_value
#     end
#     def self.invoking_method(&b)
#       meth_with_yield(&b)
#     end
#     def self.enclosing_method
#       invoking_method do
#         next :next_return_value
#         :wrong_return_value
#       end
#     end
#   end
#
#   assert_equal(:method_return_value, ChainedNextTest.enclosing_method)
# end

assert("The next statement from within the block causes ensure blocks to run") do
  ScratchPad.record([])
  [1].each do |i|
    begin
      ScratchPad.recorded << :begin
      next
    ensure
      ScratchPad.recorded << :ensure
    end
  end

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement from within the block skips following code outside an exception block") do
  ScratchPad.record([])
  3.times do |i|
    begin
      ScratchPad.recorded << :begin
      next if i == 0
      break if i == 2
      ScratchPad.recorded << :begin_end
    ensure
      ScratchPad.recorded << :ensure
    end

    ScratchPad.recorded << :after
  end

  assert_equal([ :begin, :ensure, :begin, :begin_end, :ensure, :after, :begin, :ensure], ScratchPad.recorded)
end

assert("The next statement from within the block passes the value returned by a method with omitted parenthesis and passed block") do
  ScratchPad.record([])
  obj = NextSpecs::Block.new
  assert_equal(:value, -> { next obj.method :value do |x| x end }.call)
end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The next statement in a method is invalid and raises a SyntaxError") do
#   assert_raise(SyntaxError) {
#     eval("def m; next; end")
#   }
# end

assert("The next statement in a while loop when not passed an argument causes ensure blocks to run") do
  ScratchPad.record([])
  NextSpecs.while_next(false)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a while loop when not passed an argument causes ensure blocks to run when nested in an block") do
  ScratchPad.record([])
  NextSpecs.while_within_iter(false)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a while loop when passed an argument causes ensure blocks to run") do
  ScratchPad.record([])
  NextSpecs.while_next(true)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a while loop when passed an argument causes ensure blocks to run when nested in an block") do
  ScratchPad.record([])
  NextSpecs.while_within_iter(true)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a while loop causes nested ensure blocks to run") do
  ScratchPad.record([])
  x = true
  while x
    begin
      ScratchPad.recorded << :outer_begin
      x = false
      begin
        ScratchPad.recorded << :inner_begin
        next
      ensure
        ScratchPad.recorded << :inner_ensure
      end
    ensure
      ScratchPad.recorded << :outer_ensure
    end
  end

  assert_equal([:outer_begin, :inner_begin, :inner_ensure, :outer_ensure], ScratchPad.recorded)
end

assert("The next statement in a while loop causes ensure blocks to run when mixed with break") do
  ScratchPad.record([])
  x = 1
  while true
    begin
      ScratchPad.recorded << :begin
      break if x > 1
      x += 1
      next
    ensure
      ScratchPad.recorded << :ensure
    end
  end

  assert_equal([:begin, :ensure, :begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in an until loop when not passed an argument causes ensure blocks to run") do
  ScratchPad.record([])
  NextSpecs.until_next(false)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in an until loop when not passed an argument causes ensure blocks to run when nested in an block") do
  ScratchPad.record([])
  NextSpecs.until_within_iter(false)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in an until loop when passed an argument causes ensure blocks to run") do
  ScratchPad.record([])
  NextSpecs.until_next(true)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in an until loop when passed an argument causes ensure blocks to run when nested in an block") do
  ScratchPad.record([])
  NextSpecs.until_within_iter(true)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in an until loop causes nested ensure blocks to run") do
  ScratchPad.record([])
  x = false
  until x
    begin
      ScratchPad.recorded << :outer_begin
      x = true
      begin
        ScratchPad.recorded << :inner_begin
        next
      ensure
        ScratchPad.recorded << :inner_ensure
      end
    ensure
      ScratchPad.recorded << :outer_ensure
    end
  end

  assert_equal([:outer_begin, :inner_begin, :inner_ensure, :outer_ensure], ScratchPad.recorded)
end

assert("The next statement in an until loop causes ensure blocks to run when mixed with break") do
  ScratchPad.record([])
  x = 1
  until false
    begin
      ScratchPad.recorded << :begin
      break if x > 1
      x += 1
      next
    ensure
      ScratchPad.recorded << :ensure
    end
  end

  assert_equal([:begin, :ensure, :begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a loop when not passed an argument causes ensure blocks to run") do
  ScratchPad.record([])
  NextSpecs.loop_next(false)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a loop when not passed an argument causes ensure blocks to run when nested in an block") do
  ScratchPad.record([])
  NextSpecs.loop_within_iter(false)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a loop when passed an argument causes ensure blocks to run") do
  ScratchPad.record([])
  NextSpecs.loop_next(true)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a loop when passed an argument causes ensure blocks to run when nested in an block") do
  ScratchPad.record([])
  NextSpecs.loop_within_iter(true)

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("The next statement in a loop causes nested ensure blocks to run") do
  ScratchPad.record([])
  x = 1
  loop do
    break if x == 2

    begin
      ScratchPad.recorded << :outer_begin
      begin
        ScratchPad.recorded << :inner_begin
        x += 1
        next
      ensure
        ScratchPad.recorded << :inner_ensure
      end
    ensure
      ScratchPad.recorded << :outer_ensure
    end
  end

  assert_equal([:outer_begin, :inner_begin, :inner_ensure, :outer_ensure], ScratchPad.recorded)
end

assert("The next statement in a loop causes ensure blocks to run when mixed with break") do
  ScratchPad.record([])
  x = 1
  loop do
    begin
      ScratchPad.recorded << :begin
      break if x > 1
      x += 1
      next
    ensure
      ScratchPad.recorded << :ensure
    end
  end

  assert_equal([:begin, :ensure, :begin, :ensure], ScratchPad.recorded)
end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("Assignment via next assigns objects") do
#   def r(val); a = yield(); assert_equal(a, val); end
#   r(nil){next;}
#   r(nil){next nil}
#   r(1){next 1}
#   r([]){next []}
#   r([1]){next [1]}
#   r([nil]){next [nil]}
#   r([[]]){next [[]]}
#   r([]){next [*[]]}
#   r([1]){next [*[1]]}
#   r([1,2]){next [*[1,2]]}
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("Assignment via next assigns splatted objects") do
#   def r(val); a = yield(); assert_equal(a, val); end
#   r([]){next *nil}
#   r([1]){next *1}
#   r([]){next *[]}
#   r([1]){next *[1]}
#   r([nil]){next *[nil]}
#   r([[]]){next *[[]]}
#   r([]){next *[*[]]}
#   r([1]){next *[*[1]]}
#   r([1,2]){next *[*[1,2]]}
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("Assignment via next assigns objects to a splatted reference") do
#   def r(val); *a = yield(); assert_equal(a, val); end
#   r([nil]){next;}
#   r([nil]){next nil}
#   r([1]){next 1}
#   r([]){next []}
#   r([1]){next [1]}
#   r([nil]){next [nil]}
#   r([[]]){next [[]]}
#   r([1,2]){next [1,2]}
#   r([]){next [*[]]}
#   r([1]){next [*[1]]}
#   r([1,2]){next [*[1,2]]}
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("Assignment via next assigns splatted objects to a splatted reference via a splatted yield") do
#   def r(val); *a = *yield(); assert_equal(a, val); end
#   r([]){next *nil}
#   r([1]){next *1}
#   r([]){next *[]}
#   r([1]){next *[1]}
#   r([nil]){next *[nil]}
#   r([[]]){next *[[]]}
#   r([1,2]){next *[1,2]}
#   r([]){next *[*[]]}
#   r([1]){next *[*[1]]}
#   r([1,2]){next *[*[1,2]]}
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("Assignment via next assigns objects to multiple variables") do
#   def r(val); a,b,*c = yield(); assert_equal([a,b,c], val); end
#   r([nil,nil,[]]){next;}
#   r([nil,nil,[]]){next nil}
#   r([1,nil,[]]){next 1}
#   r([nil,nil,[]]){next []}
#   r([1,nil,[]]){next [1]}
#   r([nil,nil,[]]){next [nil]}
#   r([[],nil,[]]){next [[]]}
#   r([1,2,[]]){next [1,2]}
#   r([nil,nil,[]]){next [*[]]}
#   r([1,nil,[]]){next [*[1]]}
#   r([1,2,[]]){next [*[1,2]]}
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("Assignment via next assigns splatted objects to multiple variables") do
#   def r(val); a,b,*c = *yield(); assert_equal([a,b,c], val); end
#   r([nil,nil,[]]){next *nil}
#   r([1,nil,[]]){next *1}
#   r([nil,nil,[]]){next *[]}
#   r([1,nil,[]]){next *[1]}
#   r([nil,nil,[]]){next *[nil]}
#   r([[],nil,[]]){next *[[]]}
#   r([1,2,[]]){next *[1,2]}
#   r([nil,nil,[]]){next *[*[]]}
#   r([1,nil,[]]){next *[*[1]]}
#   r([1,2,[]]){next *[*[1,2]]}
# end
