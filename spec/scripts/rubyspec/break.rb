# Derived from ruby/spec language/break_spec.rb at 0816047; MIT, see LICENSE.
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

# Fixture: ruby/spec language/fixtures/break.rb
module BreakSpecs
  class Driver
    def initialize(ensures=false)
      @ensures = ensures
    end

    def note(value)
      ScratchPad.recorded << value
    end
  end

  class Block < Driver
    def break_nil
      note :a
      note yielding {
        note :b
        break
        note :c
      }
      note :d
    end

    def break_value
      note :a
      note yielding {
        note :b
        break :break
        note :c
      }
      note :d
    end

    def yielding
      note :aa
      note yield
      note :bb
    end

    def create_block
      note :za
      b = capture_block do
        note :zb
        break :break
        note :zc
      end
      note :zd
      b
    end

    # --- BLOCKED: captures or passes a block with `&` (U001).
    # def capture_block(&b)
    #   note :xa
    #   b
    # end

    def break_in_method_captured
      note :a
      create_block.call
      note :b
    end

    # --- BLOCKED: captures or passes a block with `&` (U001).
    # def break_in_yield_captured
    #   note :a
    #   yielding(&create_block)
    #   note :b
    # end

    def break_in_method
      note :a
      b = capture_block {
        note :b
        break :break
        note :c
      }
      note :d
      note b.call
      note :e
    end

    def call_method(b)
      note :aa
      note b.call
      note :bb
    end

    def break_in_nested_method
      note :a
      b = capture_block {
        note :b
        break :break
        note :c
      }
      note :cc
      note call_method(b)
      note :d
    end

    # --- BLOCKED: captures or passes a block with `&` (U001).
    # def break_in_yielding_method
    #   note :a
    #   b = capture_block {
    #     note :b
    #     break :break
    #     note :c
    #   }
    #   note :cc
    #   note yielding(&b)
    #   note :d
    # end

    def looped_break_in_captured_block
      note :begin
      looped_delegate_block do |i|
        note :prebreak
        break if i == 1
        note :postbreak
      end
      note :end
    end

    # --- BLOCKED: captures or passes a block with `&` (U001).
    # def looped_delegate_block(&block)
    #   note :preloop
    #   2.times do |i|
    #     note :predele
    #     yield_value(i, &block)
    #     note :postdele
    #   end
    #   note :postloop
    # end
    # private :looped_delegate_block: left public, as `private` is excluded (U008).

    def yield_value(value)
      note :preyield
      yield value
      note :postyield
    end
    # private :yield_value: left public, as `private` is excluded (U008).

    def method(v)
      yield v
    end

    def invoke_yield_in_while
      looping = true
      while looping
        note :aa
        yield
        note :bb
        looping = false
      end
      note :should_not_reach_here
    end

    def break_in_block_in_while
      invoke_yield_in_while do
        note :break
        break :value
        note :c
      end
    end
  end

  class Lambda < Driver
    # Cases for the invocation of the scope defining the lambda still active
    # on the call stack when the lambda is invoked.
    def break_in_defining_scope(value=true)
      note :a
      note -> {
        note :b
        if value
          break :break
        else
          break
        end
        note :c
      }.call
      note :d
    end

    def break_in_nested_scope
      note :a
      l = -> do
        note :b
        break :break
        note :c
      end
      note :d

      invoke_lambda l

      note :e
    end

    def invoke_lambda(l)
      note :aa
      note l.call
      note :bb
    end

    # --- BLOCKED: captures or passes a block with `&` (U001).
    # def break_in_nested_scope_yield
    #   note :a
    #   l = -> do
    #     note :b
    #     break :break
    #     note :c
    #   end
    #   note :d
    #
    #   invoke_yield(&l)
    #
    #   note :e
    # end

    def note_invoke_yield
      note :aa
      note yield
      note :bb
    end

    def break_in_nested_scope_block
      note :a
      l = -> do
        note :b
        break :break
        note :c
      end
      note :d

      invoke_lambda_block l

      note :e
    end

    def invoke_yield
      note :aaa
      yield
      note :bbb
    end

    def invoke_lambda_block(b)
      note :aa
      invoke_yield do
        note :bb

        note b.call

        note :cc
      end
      note :dd
    end

    # Cases for the invocation of the scope defining the lambda NOT still
    # active on the call stack when the lambda is invoked.
    def create_lambda
      note :la
      l = -> do
        note :lb
        break :break
        note :lc
      end
      note :ld
      l
    end

    def break_in_method
      note :a

      note create_lambda.call

      note :b
    end

    def break_in_block_in_method
      note :a
      invoke_yield do
        note :b

        note create_lambda.call

        note :c
      end
      note :d
    end

    # --- BLOCKED: captures or passes a block with `&` (U001).
    # def break_in_method_yield
    #   note :a
    #
    #   invoke_yield(&create_lambda)
    #
    #   note :b
    # end
  end
end


assert("The break statement in a block returns nil to method invoking the method yielding to the block when not passed an argument") do
  ScratchPad.record([])
  @program = BreakSpecs::Block.new
  @program.break_nil
  assert_equal([:a, :aa, :b, nil, :d], ScratchPad.recorded)
end

assert("The break statement in a block returns a value to the method invoking the method yielding to the block") do
  ScratchPad.record([])
  @program = BreakSpecs::Block.new
  @program.break_value
  assert_equal([:a, :aa, :b, :break, :d], ScratchPad.recorded)
end

assert("The break statement in a block yielded inside a while breaks out of the block") do
  ScratchPad.record([])
  @program = BreakSpecs::Block.new
  value = @program.break_in_block_in_while
  assert_equal([:aa, :break], ScratchPad.recorded)
  assert_equal(:value, value)
end

# --- BLOCKED: calls a fixture method that captures a block with `&`
# (U001).
# assert("The break statement in a block captured and delegated to another method repeatedly breaks out of the block") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Block.new
#   @program.looped_break_in_captured_block
#   assert_equal([:begin, :preloop, :predele, :preyield, :prebreak, :postbreak, :postyield, :postdele, :predele, :preyield, :prebreak, :end], ScratchPad.recorded)
# end

# --- BLOCKED: `LocalJumpError` doesn't exist (SCOPE.md, Standard
# library surface).
# assert("The break statement in a captured block when the invocation of the scope creating the block is still active raises a LocalJumpError when invoking the block from the scope creating the block") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Block.new
#   assert_raise(LocalJumpError) { @program.break_in_method }
#   assert_equal([:a, :xa, :d, :b], ScratchPad.recorded)
# end

# --- BLOCKED: `LocalJumpError` doesn't exist (SCOPE.md, Standard
# library surface).
# assert("The break statement in a captured block when the invocation of the scope creating the block is still active raises a LocalJumpError when invoking the block from a method") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Block.new
#   assert_raise(LocalJumpError) { @program.break_in_nested_method }
#   assert_equal([:a, :xa, :cc, :aa, :b], ScratchPad.recorded)
# end

# --- BLOCKED: `LocalJumpError` doesn't exist (SCOPE.md, Standard
# library surface).
# assert("The break statement in a captured block when the invocation of the scope creating the block is still active raises a LocalJumpError when yielding to the block") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Block.new
#   assert_raise(LocalJumpError) { @program.break_in_yielding_method }
#   assert_equal([:a, :xa, :cc, :aa, :b], ScratchPad.recorded)
# end

# --- BLOCKED: `LocalJumpError` doesn't exist (SCOPE.md, Standard
# library surface).
# assert("The break statement in a captured block from a scope that has returned raises a LocalJumpError when calling the block from a method") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Block.new
#   assert_raise(LocalJumpError) { @program.break_in_method_captured }
#   assert_equal([:a, :za, :xa, :zd, :zb], ScratchPad.recorded)
# end

# --- BLOCKED: `LocalJumpError` doesn't exist (SCOPE.md, Standard
# library surface).
# assert("The break statement in a captured block from a scope that has returned raises a LocalJumpError when yielding to the block") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Block.new
#   assert_raise(LocalJumpError) { @program.break_in_yield_captured }
#   assert_equal([:a, :za, :xa, :zd, :aa, :zb], ScratchPad.recorded)
# end

# --- BLOCKED: uses `Thread`, which Adjutant doesn't provide.
# assert("The break statement in a captured block from another thread raises a LocalJumpError when getting the value from another thread") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Block.new
#   thread_with_break = Thread.new do
#     begin
#       break :break
#     rescue LocalJumpError => e
#       e
#     end
#   end
#   thread_with_break.value.should.instance_of?(LocalJumpError)
# end

assert("The break statement in a lambda returns from the lambda") do
  ScratchPad.record([])
  @program = BreakSpecs::Lambda.new
  l = -> {
    ScratchPad.recorded << :before
    break :foo
    ScratchPad.recorded << :after
  }
  assert_equal(:foo, l.call)
  assert_equal([:before], ScratchPad.recorded)
end

# --- BLOCKED: captures or passes a block with `&` (U001).
# assert("The break statement in a lambda returns from the call site if the lambda is passed as a block") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Lambda.new
#   def mid(&b)
#     -> {
#       ScratchPad.recorded << :before
#       b.call
#       ScratchPad.recorded << :unreachable1
#     }.call
#     ScratchPad.recorded << :unreachable2
#   end
#
#   result = [1].each do |e|
#     mid {
#       break # This breaks from mid
#       ScratchPad.recorded << :unreachable3
#     }
#     ScratchPad.recorded << :after
#   end
#   assert_equal([1], result)
#   assert_equal([:before, :after], ScratchPad.recorded)
# end

assert("The break statement in a lambda when the invocation of the scope creating the lambda is still active returns nil when not passed an argument") do
  ScratchPad.record([])
  @program = BreakSpecs::Lambda.new
  @program.break_in_defining_scope false
  assert_equal([:a, :b, nil, :d], ScratchPad.recorded)
end

assert("The break statement in a lambda when the invocation of the scope creating the lambda is still active returns a value to the scope creating and calling the lambda") do
  ScratchPad.record([])
  @program = BreakSpecs::Lambda.new
  @program.break_in_defining_scope
  assert_equal([:a, :b, :break, :d], ScratchPad.recorded)
end

assert("The break statement in a lambda when the invocation of the scope creating the lambda is still active returns a value to the method scope below invoking the lambda") do
  ScratchPad.record([])
  @program = BreakSpecs::Lambda.new
  @program.break_in_nested_scope
  assert_equal([:a, :d, :aa, :b, :break, :bb, :e], ScratchPad.recorded)
end

assert("The break statement in a lambda when the invocation of the scope creating the lambda is still active returns a value to a block scope invoking the lambda in a method below") do
  ScratchPad.record([])
  @program = BreakSpecs::Lambda.new
  @program.break_in_nested_scope_block
  assert_equal([:a, :d, :aa, :aaa, :bb, :b, :break, :cc, :bbb, :dd, :e], ScratchPad.recorded)
end

# --- BLOCKED: calls a fixture method that captures a block with `&`
# (U001).
# assert("The break statement in a lambda when the invocation of the scope creating the lambda is still active returns from the lambda") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Lambda.new
#   @program.break_in_nested_scope_yield
#   assert_equal([:a, :d, :aaa, :b, :bbb, :e], ScratchPad.recorded)
# end

# --- BLOCKED: runs a separate Ruby process (`ruby_exe`), which this
# runner can't.
# assert("The break statement in a lambda created at the toplevel returns a value when invoking from the toplevel") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Lambda.new
#   code = fixture __FILE__, "break_lambda_toplevel.rb"
#   assert_equal("a,b,break,d", ruby_exe(code).chomp)
# end

# --- BLOCKED: runs a separate Ruby process (`ruby_exe`), which this
# runner can't.
# assert("The break statement in a lambda created at the toplevel returns a value when invoking from a method") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Lambda.new
#   code = fixture __FILE__, "break_lambda_toplevel_method.rb"
#   assert_equal("a,d,b,break,e,f", ruby_exe(code).chomp)
# end

# --- BLOCKED: runs a separate Ruby process (`ruby_exe`), which this
# runner can't.
# assert("The break statement in a lambda created at the toplevel returns a value when invoking from a block") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Lambda.new
#   code = fixture __FILE__, "break_lambda_toplevel_block.rb"
#   assert_equal("a,d,f,b,break,g,e,h", ruby_exe(code).chomp)
# end

assert("The break statement in a lambda from a scope that has returned returns a value to the method scope invoking the lambda") do
  ScratchPad.record([])
  @program = BreakSpecs::Lambda.new
  @program.break_in_method
  assert_equal([:a, :la, :ld, :lb, :break, :b], ScratchPad.recorded)
end

assert("The break statement in a lambda from a scope that has returned returns a value to the block scope invoking the lambda in a method") do
  ScratchPad.record([])
  @program = BreakSpecs::Lambda.new
  @program.break_in_block_in_method
  assert_equal([:a, :aaa, :b, :la, :ld, :lb, :break, :c, :bbb, :d], ScratchPad.recorded)
end

# --- BLOCKED: calls a fixture method that captures a block with `&`
# (U001).
# assert("The break statement in a lambda from a scope that has returned raises a LocalJumpError when yielding to a lambda passed as a block argument") do
#   ScratchPad.record([])
#   @program = BreakSpecs::Lambda.new
#   @program.break_in_method_yield
#   assert_equal([:a, :la, :ld, :aaa, :lb, :bbb, :b], ScratchPad.recorded)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("Break inside a while loop with a value exits the loop and returns the value") do
#   a = while true; break; end; assert_equal(nil, a)
#   a = while true; break nil; end; assert_equal(nil, a)
#   a = while true; break 1; end; assert_equal(1, a)
#   a = while true; break []; end; assert_equal([], a)
#   a = while true; break [1]; end; assert_equal([1], a)
# end

assert("Break inside a while loop with a value passes the value returned by a method with omitted parenthesis and passed block") do
  obj = BreakSpecs::Block.new
  assert_equal(:value, -> { break obj.method :value do |x| x end }.call)
end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("Break inside a while loop with a splat exits the loop and makes the splat an Array") do
#   a = while true; break *[1,2]; end; assert_equal([1,2], a)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("Break inside a while loop with a splat treats nil as an empty array") do
#   a = while true; break *nil; end; assert_equal([], a)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("Break inside a while loop with a splat preserves an array as is") do
#   a = while true; break *[]; end; assert_equal([], a)
#   a = while true; break *[1,2]; end; assert_equal([1,2], a)
#   a = while true; break *[nil]; end; assert_equal([nil], a)
#   a = while true; break *[[]]; end; assert_equal([[]], a)
# end

# --- BLOCKED: `while` parses only as a statement (SCOPE.md, Parser /
# lexer gaps: loops parse only as statements).
# assert("Break inside a while loop with a splat wraps a non-Array in an Array") do
#   a = while true; break *1; end; assert_equal([1], a)
# end

assert("Break inside a while loop stops a while loop when run") do
  i = 0
  while true
    break if i == 2
    i+=1
  end
  assert_equal(2, i)
end

# --- BLOCKED: `Integer#upto` doesn't exist (SCOPE.md, Standard library
# surface).
# assert("Break inside a while loop causes a call with a block to return when run") do
#   at = 0
#   result = 0.upto(5) do |i|
#     at = i
#     break i if i == 2
#   end
#   assert_equal(2, result)
#   assert_equal(2, at)
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The break statement in a method is invalid and raises a SyntaxError") do
#   assert_raise(SyntaxError) {
#     eval("def m; break; end")
#   }
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The break statement in a module literal is invalid and raises a SyntaxError") do
#   code = <<~RUBY
#     module BreakSpecs:ModuleWithBreak
#       break
#     end
#   RUBY
#
#   -> { eval(code) }.should.raise(SyntaxError)
# end


# --- BLOCKED: captures or passes a block with `&` (U001).
# assert("Executing break from within a block returns from the original invoking method even in case of chained calls") do
#   ScratchPad.clear
#   class BreakTest
#     # case #1: yield
#     def self.meth_with_yield(&b)
#       yield
#       fail("break returned from yield to wrong place")
#     end
#     def self.invoking_method(&b)
#       meth_with_yield(&b)
#       fail("break returned from 'meth_with_yield' method to wrong place")
#     end
#
#     # case #2: block.call
#     def self.meth_with_block_call(&b)
#       b.call
#       fail("break returned from b.call to wrong place")
#     end
#     def self.invoking_method2(&b)
#       meth_with_block_call(&b)
#       fail("break returned from 'meth_with_block_call' method to wrong place")
#     end
#   end
#
#   # this calls a method that calls another method that yields to the block
#   BreakTest.invoking_method do
#     break
#     fail("break didn't, well, break")
#   end
#
#   # this calls a method that calls another method that calls the block
#   BreakTest.invoking_method2 do
#     break
#     fail("break didn't, well, break")
#   end
#
#   res = BreakTest.invoking_method do
#     break :return_value
#     fail("break didn't, well, break")
#   end
#   assert_equal(:return_value, res)
#
#   res = BreakTest.invoking_method2 do
#     break :return_value
#     fail("break didn't, well, break")
#   end
#   assert_equal(:return_value, res)
#
# end



class BreakTest2
  def one
    two { yield }
  end
  def two
    yield
  ensure
    ScratchPad.recorded << :two_ensure
  end
  def three
    begin
      one { break; }
      ScratchPad.recorded << :three_post
    ensure
      ScratchPad.recorded << :three_ensure
    end
  end
end

assert("Executing break from within a block runs ensures when continuing upward") do
  ScratchPad.clear
  ScratchPad.record([])

  bt2 = BreakTest2.new
  bt2.one { break; }
  assert_equal([:two_ensure], ScratchPad.recorded)
end

assert("Executing break from within a block runs ensures when breaking from a loop") do
  ScratchPad.clear
  ScratchPad.record([])

  while true
    begin
      ScratchPad.recorded << :begin
      break if true
    ensure
      ScratchPad.recorded << :ensure
    end
  end

  assert_equal([:begin, :ensure], ScratchPad.recorded)
end

assert("Executing break from within a block doesn't run ensures in the destination method") do
  ScratchPad.clear
  ScratchPad.record([])

  bt2 = BreakTest2.new
  bt2.three
  assert_equal([:two_ensure, :three_post, :three_ensure], ScratchPad.recorded)
end

# --- BLOCKED: `super` takes no block (SCOPE.md, Parser / lexer gaps).
# assert("Executing break from within a block works when passing through a super call") do
#   ScratchPad.clear
#   class BreakSpecsSuper1
#     def foo
#       yield
#     end
#   end
#
#   class BreakSpecsSuper2 < BreakSpecsSuper1
#     def foo
#       super { break 1 }
#     end
#   end
#
#   assert_nothing_raised do
#     assert_equal(1, BreakSpecsSuper2.new.foo)
#   end
# end

# --- BLOCKED: captures the block with `&b` (U001) and builds classes
# with `Class.new` (U002).
# assert("Executing break from within a block raises LocalJumpError when converted into a proc during a super call") do
#   ScratchPad.clear
#   cls1 = Class.new { def foo(&b); b; end }
#   cls2 = Class.new(cls1) { def foo; super { break 1 }.call; end }
#
#   -> do
#     cls2.new.foo
#   end.should.raise(LocalJumpError)
# end
