require "assert"

##
# Range ISO Test
#
# Two things worth knowing up front, since they block or shape nearly
# every block below:
#
# 1. ENDLESS/BEGINLESS RANGES (`1..`, `..10`, `1...`, `...10`) DON'T
#    PARSE AT ALL — `parse_range` (parser.cr) always calls
#    `parse_expression` unconditionally for both sides of `..`/`...`,
#    with no way to omit either. A real, tracked Must Fix gap (see
#    SCOPE.md) — not fixed here. Every assertion below using a
#    partial range is left commented for this reason specifically;
#    said so once here rather than repeating it at every site.
# 2. `a === b` AS A GENERAL INFIX EXPRESSION IS A DELIBERATE, PERMANENT
#    DESIGN DECISION, not a gap — `case/when` (the real caller of
#    `Class#===`/`Range#===`) is compiler-generated dispatch, never
#    parsed from literal `a === b` script syntax; see UNSUPPORTED.md's
#    entry on `===`/other operator methods for the full reasoning.
#    `Range#===`'s own block below is blocked for this reason, not a
#    missing-feature one — rewriting it as `case`/`when` would
#    actually exercise the real underlying behavior, but that's a
#    different test than upstream's own, so left as a clear note
#    instead of a silent rewrite.

assert('Range', '15.2.14') do
  assert_equal Class, Range.class
end

# --- Trimmed: two ranges failing to compare equal was a REAL bug,
# now fixed (ValueOps had no Range-specific content-equality case —
# see vm.cr's range_values_equal?) — those two lines are uncommented
# below. Every other assertion in this block needs either a partial
# range or Object.const_defined? (a separate, already-tracked gap) —
# left blocked.
assert('Range#==', '15.2.14.4.1') do
  assert_true (1..10) == (1..10)
  assert_false (1..10) == (1..100)
end
# assert('Range#== (partial ranges)') do
#   assert_false (1..10) == (1..)
#   assert_false (1..10) == (..10)
#   assert_true (1..) == (1..nil)
#   assert_true (1..) == (1..)
#   assert_false (1..) == (1...)

#   assert_true (..1) == (nil..1)
#   assert_true (..1) == (..1)
#   assert_false (..1) == (...1)
# end
# assert('Range#== (Float bound)') do
#   skip unless Object.const_defined?(:Float)
#   assert_true (1..10) == Range.new(1.0, 10.0)
# end

# --- BLOCKED: `a === b` as literal infix syntax is a deliberate
# non-goal (see file header) — not reachable via case/when's own
# compiler-generated dispatch either, since that's a different test
# shape than what's written here. Also needs partial ranges for two
# of its three receivers.
# assert('Range#===', '15.2.14.4.2') do
#   a = (1..10)
#   b = (1..)
#   c = (..10)

#   assert_true a === 5
#   assert_false a === 20
#   assert_true b === 20
#   assert_false b === 0
#   assert_false c === 20
#   assert_true c === 0
# end

# --- Trimmed: `Range.new(1, 10, true)` (no __send__ involved) DOES
# work now — a native `Range.new` singleton didn't exist before
# (fell through to a bare, ivar-less RubyObject; see range.cr's own
# comment on this). The `c`/`d` sub-case (`Range.new(1, nil, true)`)
# is included too: `1...nil` isn't a PARTIAL range syntactically (an
# explicit `nil` token is present, just parsed as an ordinary
# NilLiteral operand) — different from the omitted-token case
# `1...` is, so not blocked by the parsing gap. Only the __send__
# line is dropped.
assert('Range#initialize', '15.2.14.4.9') do
  a = Range.new(1, 10, true)
  b = Range.new(1, 10, false)

  assert_equal (1...10), a
  assert_true a.exclude_end?
  assert_equal (1..10), b
  assert_false b.exclude_end?

  c = Range.new(1, nil, true)
  d = Range.new(1, nil, false)

  assert_equal (1...nil), c
  assert_true c.exclude_end?
  assert_equal (1..nil), d
  assert_false d.exclude_end?
end
# assert('Range#initialize (__send__)') do
#   assert_raise(NameError) { (0..1).__send__(:initialize, 1, 3) }
# end

assert('Range#each', '15.2.14.4.4') do
  a = (1..3)
  b = 0
  a.each {|i| b += i}
  assert_equal 6, b
end
# assert('Range#each (endless)') do
#   c = []
#   (1..).each { |i| c << i; break if c.size == 10 }
#   assert_equal [1, 2, 3, 4, 5, 6, 7, 8 ,9, 10], c
# end

# --- Trimmed: `#begin`/`#end` now exist (real Ruby names — this
# class previously only had `#min`/`#max` under those names). The
# endless-range sub-cases still need partial ranges.
assert('Range#begin', '15.2.14.4.3') do
  assert_equal 1, (1..10).begin
end
# assert('Range#begin (partial ranges)') do
#   assert_equal 1, (1..).begin
#   assert_nil (..1).begin
# end

assert('Range#end', '15.2.14.4.5') do
  assert_equal 10, (1..10).end
end
# assert('Range#end (partial ranges)') do
#   assert_nil (1..).end
#   assert_equal 10, (..10).end
# end

# --- Trimmed: `#exclude_end?` now exists (real Ruby name — this
# class previously only had the non-standard `#exclusive?`).
assert('Range#exclude_end?', '15.2.14.4.6') do
  assert_true (1...10).exclude_end?
  assert_false (1..10).exclude_end?
end
# assert('Range#exclude_end? (partial ranges)') do
#   assert_true (1...).exclude_end?
#   assert_false (1..).exclude_end?
#   assert_true (...1).exclude_end?
#   assert_false (..1).exclude_end?
# end

assert('Range#first', '15.2.14.4.7') do
  assert_equal 1, (1..10).first
end
# assert('Range#first (endless)') do
#   assert_equal 1, (1..).first
# end

assert('Range#include?', '15.2.14.4.8') do
  assert_true (1..10).include?(10)
  assert_false (1..10).include?(11)
  assert_true (1...10).include?(9)
  assert_false (1...10).include?(10)
end
# assert('Range#include? (partial ranges)') do
#   assert_true (1..).include?(10)
#   assert_false (1..).include?(0)
#   assert_true (..10).include?(10)
#   assert_true (..10).include?(0)
#   assert_true (1...).include?(10)
#   assert_false (1...).include?(0)
#   assert_false (...10).include?(10)
#   assert_true (...10).include?(0)
# end

assert('Range#last', '15.2.14.4.10') do
  assert_equal 10, (1..10).last
end
# assert('Range#last (endless)') do
#   assert_nil (1..).last
# end

assert('Range#member?', '15.2.14.4.11') do
  a = (1..10)

  assert_true a.member?(5)
  assert_false a.member?(20)
end
# assert('Range#member? (endless)') do
#   b = (1..)
#   assert_true b.member?(20)
#   assert_false b.member?(0)
# end

# --- Trimmed: to_s doesn't need partial ranges for these four (a
# String-bounded range doesn't need String#succ just to render, only
# to actually iterate) — only the endless-range variants below are
# blocked.
assert('Range#to_s', '15.2.14.4.12') do
  assert_equal "0..1", (0..1).to_s
  assert_equal "0...1", (0...1).to_s
  assert_equal "a..b", ("a".."b").to_s
  assert_equal "a...b", ("a"..."b").to_s
end
# assert('Range#to_s (partial ranges)') do
#   assert_equal "0..", (0..).to_s
#   assert_equal "0...", (0...).to_s
#   assert_equal "a..", ("a"..).to_s
#   assert_equal "a...", ("a"...).to_s
# end

# --- BLOCKED: Range#inspect isn't registered as a native method at
# all (only #to_s exists) — blocked regardless of the partial-range
# issue, which would ALSO block half of this block anyway.
# assert('Range#inspect', '15.2.14.4.13') do
#   assert_equal "0..1", (0..1).inspect
#   assert_equal "0...1", (0...1).inspect
#   assert_equal "\"a\"..\"b\"", ("a".."b").inspect
#   assert_equal "\"a\"...\"b\"", ("a"..."b").inspect
#   assert_equal "0..", (0..).inspect
#   assert_equal "0...", (0...).inspect
#   assert_equal "\"a\"..", ("a"..).inspect
#   assert_equal "\"a\"...", ("a"...).inspect
# end

# --- BLOCKED: Range#eql? doesn't exist for any type yet (see
# SCOPE.md — not Range-specific). Would ALSO need partial ranges for
# half of this block regardless.
# assert('Range#eql?', '15.2.14.4.14') do
#   assert_true (1..10).eql? (1..10)
#   assert_false (1..10).eql? (1..100)
#   assert_false (1..10).eql? "1..10"
#   assert_true (1..).eql? (1..)
#   assert_false (1..).eql? (2..)
#   assert_false (1..).eql? "1.."
#   skip unless Object.const_defined?(:Float)
#   assert_false (1..10).eql? (Range.new(1.0, 10.0))
#   assert_false (1..).eql? (Range.new(1.0, nil))
# end

# --- BLOCKED: __send__ is deliberately excluded (U005).
# assert('Range#initialize_copy', '15.2.14.4.15') do
#   assert_raise(NameError) { (0..1).__send__(:initialize_copy, 1..3) }
# end

# --- BLOCKED: Range#hash doesn't exist for any type yet (see
# SCOPE.md — not Range-specific).
# assert('Range#hash', '15.3.1.3.15') do
#   assert_kind_of(Integer, (1..10).hash)
#   assert_equal (1..10).hash, (1..10).hash
#   assert_not_equal (1..10).hash, (1...10).hash
#   assert_equal (1..).hash, (1..).hash
#   assert_not_equal (1..).hash, (1...).hash
# end

# --- BLOCKED: #dup/#clone on a builtin-kind receiver raises
# NoMethodError rather than copying (see SCOPE.md's Will Fix entry) —
# would ALSO need partial ranges for the third sub-case regardless.
# assert('Range#dup') do
#   r = (1..3).dup
#   assert_equal 1, r.begin
#   assert_equal 3, r.end
#   assert_false r.exclude_end?

#   r = ("a"..."z").dup
#   assert_equal "a", r.begin
#   assert_equal "z", r.end
#   assert_true r.exclude_end?

#   r = (1..).dup
#   assert_equal 1, r.begin
#   assert_nil r.end
#   assert_false r.exclude_end?
# end

assert('Range#to_a') do
  assert_equal([1, 2, 3, 4, 5], (1..5).to_a)
  assert_equal([1, 2, 3, 4], (1...5).to_a)
end
# assert('Range#to_a (endless)') do
#   assert_raise(RangeError) { (1..).to_a }
# end
