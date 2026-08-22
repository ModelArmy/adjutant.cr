require "assert"

##
# Range ISO Test
#
# Endless/beginless range SYNTAX (`1..`, `..10`, `1...`, `...10`) now
# parses and works end to end — this was the file's original blocker
# (see git history for the fix, `endless-ranges` branch, 2026-08-18).
# Assertions using a partial range are uncommented below wherever the
# underlying method has real nil-bound handling; a few still-blocked
# ones are left commented with their own specific reason, not the old
# blanket one. Two things still worth knowing up front:
#
# 1. INFIX `a === b` NOW PARSES AND WORKS (added 2026-08-21 — `===`
#    joined `==` as a fixed VM opcode, `Op::TripleEq`; see
#    DEVELOPMENT.md's "Comparison operators" entry), AND `Range#===`
#    now has real nil-bound handling too (added 2026-08-22, fixing the
#    SCOPE.md Must Fix entry this file's own `Range#===` block flagged
#    the same day — `range_include?`, `vm.cr`, previously fell through
#    `ValueOps.compare`'s `nil`-has-no-matching-branch `else -> false`
#    for a beginless/endless range's missing bound, silently answering
#    `false` for a genuinely included value on that side). The
#    `Range#===` block below is fully active now, partial ranges
#    included — no longer split or partially blocked.
# 2. `Range#last`/`Range#max`/`Range#min`/`Range#first` (no argument)
#    all correctly raise `RangeError` on the relevant nil bound as of
#    2026-08-19 (four DISTINCT messages, confirmed via Ruby's own C
#    source, not assumed — `#max`/`#last` both fire on a nil END but
#    word it differently; `#min`/`#first` both fire on a nil BEGIN,
#    likewise worded differently from each other). `#first` was fixed
#    in a separate follow-up after the other three, since real Ruby
#    added its beginless check later, as its own feature request,
#    once the `#last`/`#first` inconsistency was noticed upstream.
#    Endless `#first` was never the problem either way — real Ruby
#    correctly never raises there (there's always a genuine first
#    value regardless of where a range ends), so that direction
#    needed no fix and has none.

assert('Range', '15.2.14') do
  assert_equal Class, Range.class
end

# --- Trimmed: two ranges failing to compare equal was a REAL bug,
# now fixed (ValueOps had no Range-specific content-equality case —
# see vm.cr's range_values_equal?). Partial-range equality is
# uncommented below too, now that the syntax parses; only the
# Float-bound sub-case (needs Object.const_defined?, a separate,
# already-tracked gap) stays blocked.
assert('Range#==', '15.2.14.4.1') do
  assert_true (1..10) == (1..10)
  assert_false (1..10) == (1..100)
end
assert('Range#== (partial ranges)') do
  assert_false (1..10) == (1..)
  assert_false (1..10) == (..10)
  assert_true (1..) == (1..nil)
  assert_true (1..) == (1..)
  assert_false (1..) == (1...)

  assert_true (..1) == (nil..1)
  assert_true (..1) == (..1)
  assert_false (..1) == (...1)
end
# assert('Range#== (Float bound)') do
#   skip unless Object.const_defined?(:Float)
#   assert_true (1..10) == Range.new(1.0, 10.0)
# end

assert('Range#===', '15.2.14.4.2') do
  a = (1..10)
  b = (1..)
  c = (..10)

  assert_true a === 5
  assert_false a === 20
  assert_true b === 20
  assert_false b === 0
  assert_false c === 20
  assert_true c === 0
end

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
# --- BLOCKED, but NOT by anything range-related — `break if cond`
# (no explicit break value) immediately followed by a closing `}`
# hits a separate, still-open parser bug: `parse_break` grabs its own
# optional VALUE via `parse_expression(0)` before ever checking for a
# trailing `KwIf` modifier, and `if` is itself a valid expression-
# START token, so `break if c.size == 10 }` tries to parse `if
# c.size == 10 }` as break's own value (a real if-expression) instead
# of stopping after `if c.size == 10` and treating it as the
# modifier. See SCOPE.md's "`break if cond; more_code`" Will Fix
# entry for the full writeup — not fixed here, deliberately left as
# upstream wrote it rather than rewritten to dodge an unrelated bug.
# assert('Range#each (endless)') do
#   c = []
#   (1..).each { |i| c << i; break if c.size == 10 }
#   assert_equal [1, 2, 3, 4, 5, 6, 7, 8 ,9, 10], c
# end

# --- Trimmed: `#begin`/`#end` now exist (real Ruby names — this
# class previously only had `#min`/`#max` under those names). The
# endless-range sub-cases are uncommented below too, now that
# partial-range syntax parses.
assert('Range#begin', '15.2.14.4.3') do
  assert_equal 1, (1..10).begin
end
assert('Range#begin (partial ranges)') do
  assert_equal 1, (1..).begin
  assert_nil (..1).begin
end

assert('Range#end', '15.2.14.4.5') do
  assert_equal 10, (1..10).end
end
assert('Range#end (partial ranges)') do
  assert_nil (1..).end
  assert_equal 10, (..10).end
end

# --- Trimmed: `#exclude_end?` now exists (real Ruby name — this
# class previously only had the non-standard `#exclusive?`).
assert('Range#exclude_end?', '15.2.14.4.6') do
  assert_true (1...10).exclude_end?
  assert_false (1..10).exclude_end?
end
assert('Range#exclude_end? (partial ranges)') do
  assert_true (1...).exclude_end?
  assert_false (1..).exclude_end?
  assert_true (...1).exclude_end?
  assert_false (..1).exclude_end?
end

assert('Range#first', '15.2.14.4.7') do
  assert_equal 1, (1..10).first
end
assert('Range#first (endless)') do
  assert_equal 1, (1..).first
end

assert('Range#include?', '15.2.14.4.8') do
  assert_true (1..10).include?(10)
  assert_false (1..10).include?(11)
  assert_true (1...10).include?(9)
  assert_false (1...10).include?(10)
end
assert('Range#include? (partial ranges)') do
  assert_true (1..).include?(10)
  assert_false (1..).include?(0)
  assert_true (..10).include?(10)
  assert_true (..10).include?(0)
  assert_true (1...).include?(10)
  assert_false (1...).include?(0)
  assert_false (...10).include?(10)
  assert_true (...10).include?(0)
end

assert('Range#last', '15.2.14.4.10') do
  assert_equal 10, (1..10).last
end
assert('Range#last (endless)') do
  # Rewritten from upstream's own `assert_nil (1..).last` — that
  # assertion was already wrong relative to real Ruby (confirmed via
  # Ruby's own C source: raises RangeError, doesn't return nil), not
  # just relative to Adjutant's old (also wrong, in the same way)
  # implementation. Fixed on both sides now, so this asserts the
  # real answer rather than perpetuating upstream's own mistake.
  assert_raise(RangeError) { (1..).last }
end

assert('Range#member?', '15.2.14.4.11') do
  a = (1..10)

  assert_true a.member?(5)
  assert_false a.member?(20)
end
assert('Range#member? (endless)') do
  b = (1..)
  assert_true b.member?(20)
  assert_false b.member?(0)
end

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
assert('Range#to_s (partial ranges)') do
  assert_equal "0..", (0..).to_s
  assert_equal "0...", (0...).to_s
  assert_equal "a..", ("a"..).to_s
  assert_equal "a...", ("a"...).to_s
end

assert('Range#inspect', '15.2.14.4.13') do
  assert_equal "0..1", (0..1).inspect
  assert_equal "0...1", (0...1).inspect
  assert_equal "\"a\"..\"b\"", ("a".."b").inspect
  assert_equal "\"a\"...\"b\"", ("a"..."b").inspect
  assert_equal "0..", (0..).inspect
  assert_equal "0...", (0...).inspect
  assert_equal "\"a\"..", ("a"..).inspect
  assert_equal "\"a\"...", ("a"...).inspect
end

# --- BLOCKED: Range#eql? doesn't exist for any type yet (see
# SCOPE.md — not Range-specific). Partial ranges themselves parse
# fine now — this is the only remaining blocker.
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
# NoMethodError rather than copying (see SCOPE.md's Will Fix entry).
# Partial ranges themselves parse fine now — this is the only
# remaining blocker.
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
assert('Range#to_a (endless)') do
  assert_raise(RangeError) { (1..).to_a }
end
