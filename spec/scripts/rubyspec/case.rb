# Derived from ruby/spec language/case_spec.rb at 0816047; MIT, see LICENSE.
require "assert"

assert("The 'case'-construct evaluates the body of the when clause matching the case target expression") do
  result = case 1
  when 2; false
  when 1; true
  end
  assert_equal(true, result)
end

assert("The 'case'-construct evaluates the body of the when clause whose array expression includes the case target expression") do
  result = case 2
  when 3, 4; false
  when 1, 2; true
  end
  assert_equal(true, result)
end

assert("The 'case'-construct evaluates the body of the when clause in left-to-right order if it's an array expression") do
  @calls = []
  def foo; @calls << :foo; end
  def bar; @calls << :bar; end

  case true
  when foo, bar;
  end

  assert_equal([:foo, :bar], @calls)
end

assert("The 'case'-construct matches an Integer literal whose value does not fit in a 32-bit int") do
  big = 10_000_000_000
  result = case big
  when 10_000_000_000; true
  else                 false
  end
  assert_equal(true, result)

  result = case -3_000_000_000
  when -3_000_000_000; true
  else                 false
  end
  assert_equal(true, result)
end

# --- BLOCKED: Integers outside 64 bits are excluded (U025).
# assert("The 'case'-construct matches an arbitrary-precision Integer literal") do
#   huge = 1267650600228229401496703205376
#   result = case huge
#   when 1267650600228229401496703205376; true
#   else                                  false
#   end
#   assert_equal(true, result)
# end

# --- BLOCKED: Integers outside 64 bits are excluded (U025), and a
# lambda's parameters must be parenthesised (SCOPE.md, Parser / lexer
# gaps).
# assert("The 'case'-construct dispatches correctly with mixed small and large Integer literals") do
#   pick = -> x {
#     case x
#     when 1267650600228229401496703205376 then :beyond_long
#     when 10_000_000_000                  then :beyond_int
#     when 1                               then :fits_int
#     else                                      :other
#     end
#   }
#
#   assert_equal([:beyond_long, :beyond_int, :fits_int, :other],
#     [1267650600228229401496703205376, 10_000_000_000, 1, :nope].map(&pick))
# end

assert("The 'case'-construct evaluates the body of the when clause whose range expression includes the case target expression") do
  result = case 5
  when 21..30; false
  when 1..20; true
  end
  assert_equal(true, result)
end

assert("The 'case'-construct returns nil when no 'then'-bodies are given") do
  result = case "a"
  when "a"
  when "b"
  end
  assert_equal(nil, result)
end

assert("The 'case'-construct evaluates the 'else'-body when no other expression matches") do
  result = case "c"
  when "a"; 'foo'
  when "b"; 'bar'
  else 'zzz'
  end
  assert_equal('zzz', result)
end

assert("The 'case'-construct returns nil when no expression matches and 'else'-body is empty") do
  result = case "c"
  when "a"; "a"
  when "b"; "b"
  else
  end
  assert_equal(nil, result)
end

# --- BLOCKED: there is no `Numeric` class (SCOPE.md, Object model).
# assert("The 'case'-construct returns 2 when a then body is empty") do
#   result = case Object.new
#   when Numeric then
#     1
#   when String then
#     # ok
#   else
#     2
#   end
#   assert_equal(2, result)
# end

assert("The 'case'-construct returns the statement following 'then'") do
  result = case "a"
  when "a" then 'foo'
  when "b" then 'bar'
  end
  assert_equal('foo', result)
end

assert("The 'case'-construct tests classes with case equality") do
  result = case "a"
  when String
    'foo'
  when Symbol
    'bar'
  end
  assert_equal('foo', result)
end

assert("The 'case'-construct tests with matching regexps") do
  result = case "hello"
  when /abc/; false
  when /^hell/; true
  end
  assert_equal(true, result)
end

# --- BLOCKED: tests `$~` and `$1`, which are globals (U011).
# assert("The 'case'-construct tests with matching regexps and sets $~ and captures") do
#   case "foo42"
#   when /oo(\d+)/
#     assert_true($~.is_a?(MatchData))
#     assert_equal("42", $1)
#   else
#     flunk
#   end
#   assert_true($~.is_a?(MatchData))
#   assert_equal("42", $1)
# end

# --- BLOCKED: tests `$~` and `$1`, which are globals (U011).
# assert("The 'case'-construct tests with a string interpolated in a regexp") do
#   digits = '\d+'
#   case "foo44"
#   when /oo(#{digits})/
#     assert_true($~.is_a?(MatchData))
#     assert_equal("44", $1)
#   else
#     flunk
#   end
#   assert_true($~.is_a?(MatchData))
#   assert_equal("44", $1)
# end

# --- BLOCKED: tests `$~` and `$1`, which are globals (U011).
# assert("The 'case'-construct tests with a regexp interpolated within another regexp") do
#   digits_regexp = /\d+/
#   case "foo43"
#   when /oo(#{digits_regexp})/
#     assert_true($~.is_a?(MatchData))
#     assert_equal("43", $1)
#   else
#     flunk
#   end
#   assert_true($~.is_a?(MatchData))
#   assert_equal("43", $1)
# end

assert("The 'case'-construct does not test with equality when given classes") do
  result = case :symbol.class
  when Symbol
    "bar"
  when String
    "bar"
  else
    "foo"
  end
  assert_equal("foo", result)
end

assert("The 'case'-construct takes lists of values") do
  result = case 'z'
  when 'a', 'b', 'c', 'd'
    "foo"
  when 'x', 'y', 'z'
    "bar"
  end
  assert_equal("bar", result)

  result = case 'b'
  when 'a', 'b', 'c', 'd'
    "foo"
  when 'x', 'y', 'z'
    "bar"
  end
  assert_equal("foo", result)
end

assert("The 'case'-construct tests an empty array") do
  result = case []
  when []
    'foo'
  else
    'bar'
  end
  assert_equal('foo', result)
end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct expands arrays to lists of values") do
#   result = case 'z'
#   when *['a', 'b', 'c', 'd']
#     "foo"
#   when *['x', 'y', 'z']
#     "bar"
#   end
#   assert_equal("bar", result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct takes an expanded array in addition to a list of values") do
#   result = case 'f'
#   when 'f', *['a', 'b', 'c', 'd']
#     "foo"
#   when *['x', 'y', 'z']
#     "bar"
#   end
#   assert_equal("foo", result)
#
#   result = case 'b'
#   when 'f', *['a', 'b', 'c', 'd']
#     "foo"
#   when *['x', 'y', 'z']
#     "bar"
#   end
#   assert_equal("foo", result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct takes an expanded array before additional listed values") do
#   result = case 'f'
#   when *['a', 'b', 'c', 'd'], 'f'
#     "foo"
#   when *['x', 'y', 'z']
#     "bar"
#   end
#   assert_equal('foo', result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct expands arrays from variables before additional listed values") do
#   a = ['a', 'b', 'c']
#   result = case 'a'
#   when *a, 'd', 'e'
#     "foo"
#   when 'x'
#     "bar"
#   end
#   assert_equal("foo", result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct expands arrays from variables before a single additional listed value") do
#   a = ['a', 'b', 'c']
#   result = case 'a'
#   when *a, 'd'
#     "foo"
#   when 'x'
#     "bar"
#   end
#   assert_equal("foo", result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct expands multiple arrays from variables before additional listed values") do
#   a = ['a', 'b', 'c']
#   b = ['d', 'e', 'f']
#
#   result = case 'f'
#   when *a, *b, 'g', 'h'
#     "foo"
#   when 'x'
#     "bar"
#   end
#   assert_equal("foo", result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct concats arrays before expanding them") do
#   a = ['a', 'b', 'c', 'd']
#   b = ['f']
#
#   result = case 'f'
#   when 'f', *a|b
#     "foo"
#   when *['x', 'y', 'z']
#     "bar"
#   end
#   assert_equal("foo", result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct never matches when clauses with no values") do
#   result = case nil
#   when *[]
#     "foo"
#   end
#   assert_equal(nil, result)
# end

# --- BLOCKED: parentheses hold exactly one expression, not a statement
# such as `def` (SCOPE.md, Parser / lexer gaps).
# assert("The 'case'-construct lets you define a method after the case statement") do
#   result = case (def foo; 'foo'; end; 'f')
#   when 'a'
#     'foo'
#   when 'f'
#     'bar'
#   end
#   assert_equal('bar', result)
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The 'case'-construct raises a SyntaxError when 'else' is used when no 'when' is given") do
#   assert_raise(SyntaxError) {
#     eval <<-CODE
#     case 4
#     else
#       true
#     end
#     CODE
#   }
# end

# --- BLOCKED: tests a SyntaxError raised through `eval` (U006).
# assert("The 'case'-construct raises a SyntaxError when 'else' is used before a 'when' was given") do
#   assert_raise(SyntaxError) {
#     eval <<-CODE
#     case 4
#     else
#       true
#     when 4; false
#     end
#     CODE
#   }
# end

assert("The 'case'-construct supports nested case statements") do
  result = false
  case :x
  when Symbol
    case :y
    when Symbol
      result = true
    end
  end
  assert_equal(true, result)
end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct supports nested case statements followed by a when with a splatted array") do
#   result = false
#   case :x
#   when Symbol
#     case :y
#     when Symbol
#       result = true
#     end
#   when *[Symbol]
#     result = false
#   end
#   assert_equal(true, result)
# end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct supports nested case statements followed by a when with a splatted non-array") do
#   result = false
#   case :x
#   when Symbol
#     case :y
#     when Symbol
#       result = true
#     end
#   when *Symbol
#     result = false
#   end
#   assert_equal(true, result)
# end

assert("The 'case'-construct works even if there's only one when statement") do
  result = case 1
  when 1
    100
  end
  assert_equal(100, result)
end

assert("The 'case'-construct evaluates true as only 'true' when true is the first clause") do
  result = case 1
  when true; "bad"
  when Integer; "good"
  end
  assert_equal("good", result)
end

assert("The 'case'-construct evaluates false as only 'false' when false is the first clause") do
  result = case nil
  when false; "bad"
  when nil; "good"
  end
  assert_equal("good", result)
end

assert("The 'case'-construct treats a literal array as its own when argument, rather than a list of arguments") do
  result = case 'foo'
  when ['foo', 'foo']; 'bad'
  when 'foo'; 'good'
  end
  assert_equal('good', result)
end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct takes multiple expanded arrays") do
#   a1 = ['f', 'o', 'o']
#   a2 = ['b', 'a', 'r']
#
#   result = case 'f'
#   when *a1, *['x', 'y', 'z']
#     "foo"
#   when *a2, *['x', 'y', 'z']
#     "bar"
#   end
#   assert_equal("foo", result)
#
#   result = case 'b'
#   when *a1, *['x', 'y', 'z']
#     "foo"
#   when *a2, *['x', 'y', 'z']
#     "bar"
#   end
#   assert_equal("bar", result)
# end

# --- BLOCKED: `private`, `protected` and `public` are excluded (U008).
# assert("The 'case'-construct calls === even when private") do
#   klass = Class.new do
#     def ===(o)
#       true
#     end
#     private :===
#   end
#
#   result = case 1
#   when klass.new
#     :called
#   end
#   assert_equal(:called, result)
# end

# --- BLOCKED: parentheses hold exactly one expression (SCOPE.md, Parser
# / lexer gaps).
# assert("The 'case'-construct accepts complex expressions within ()") do
#   result = case 'a'
#   when (raise if 2+2 == 3; /a/)
#     :called
#   end
#   assert_equal(:called, result)
# end

# --- BLOCKED: parentheses hold exactly one expression, so `('a'; 'b')`
# doesn't parse (SCOPE.md, Parser / lexer gaps).
# assert("The 'case'-construct only matches last value in complex expressions within ()") do
#   result = case 'a'
#   when ('a'; 'b')
#     :wrong_called
#   when ('b'; 'a')
#     :called
#   end
#   assert_equal(:called, result)
# end

# --- BLOCKED: `Object#then` doesn't exist (SCOPE.md, Standard library
# surface).
# assert("The 'case'-construct supports declaring variables in the case target expression") do
#   def test(v)
#     case new_variable_in_expression = v
#     when true
#       # This extra block is a test that `new_variable_in_expression` is declared outside of it and not inside
#       self.then { new_variable_in_expression }
#     else
#       # Same
#       self.then { new_variable_in_expression.casecmp?("foo") }
#     end
#   end
#
#   assert_equal(false, self.test("bar"))
#   assert_equal(true, self.test(true))
# end

# --- BLOCKED: tests a parse-time warning, which Adjutant doesn't emit.
# assert("The 'case'-construct warns if there are identical when clauses") do
#   -> {
#     eval <<~RUBY
#       case 1
#       when 2
#         :foo
#       when 2
#         :bar
#       end
#     RUBY
#   }.should complain(/warning: 'when' clause on line \d+ duplicates 'when' clause on line \d+ and is ignored/, verbose: true)
# end


assert("The 'case'-construct with no target expression evaluates the body of the first clause when at least one of its condition expressions is true") do
  result = case
  when true, false; 'foo'
  end
  assert_equal('foo', result)
end

assert("The 'case'-construct with no target expression evaluates the body of the first when clause that is not false/nil") do
  result = case
  when false; 'foo'
  when 2; 'bar'
  when 1 == 1; 'baz'
  end
  assert_equal('bar', result)

  result = case
  when false; 'foo'
  when nil; 'foo'
  when 1 == 1; 'bar'
  end
  assert_equal('bar', result)
end

assert("The 'case'-construct with no target expression evaluates the body of the else clause if all when clauses are false/nil") do
  result = case
  when false; 'foo'
  when nil; 'foo'
  when 1 == 2; 'bar'
  else 'baz'
  end
  assert_equal('baz', result)
end

assert("The 'case'-construct with no target expression evaluates multiple conditional expressions as a boolean disjunction") do
  result = case
  when true, false; 'foo'
  else 'bar'
  end
  assert_equal('foo', result)

  result = case
  when false, true; 'foo'
  else 'bar'
  end
  assert_equal('foo', result)
end

assert("The 'case'-construct with no target expression handles homogeneous cases") do
  result = case
  when 1; 'foo'
  when 2; 'bar'
  end
  assert_equal('foo', result)
end

# --- BLOCKED: a splat outside a parameter list doesn't parse (SCOPE.md,
# Parser / lexer gaps: call-site splat).
# assert("The 'case'-construct with no target expression expands arrays to lists of values") do
#   result = case
#   when *[false]
#     "foo"
#   when *[true]
#     "bar"
#   end
#   assert_equal("bar", result)
# end
