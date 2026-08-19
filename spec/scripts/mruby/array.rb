require "assert"

##
# Array ISO Test

assert('Array', '15.2.12') do
  assert_equal(Class, Array.class)
end

# --- BLOCKED: no Enumerable module exists, and Module#include? (the
# query method, distinct from the `include` keyword) isn't
# implemented for any class.
# assert('Array included modules', '15.2.12.3') do
#   assert_true(Array.include?(Enumerable))
# end

# --- BLOCKED: `Array.[]` (a singleton method) isn't registered —
# array.cr only defines instance methods. Real Ruby's array LITERAL
# syntax doesn't go through this at all, so this is specifically about
# the `Array[...]` / `Array.[](...)` construction form.
# assert('Array.[]', '15.2.12.4.1') do
#   assert_equal([1, 2, 3], Array.[](1,2,3))
# end

# --- BLOCKED: depends on Array.[] above.
# class SubArray < Array
# end

# assert('SubArray.[]') do
#   a = SubArray[1, 2, 3]
#   assert_equal(SubArray, a.class)
# end

# --- BLOCKED: `+` is opcode-only (Op::Add / ValueOps.add), not
# registered in find_native_method — infix `[1] + [1]` already works
# (see array_spec.cr's own regression coverage) but this explicit
# dot-call form (`.+(...)`) isn't reachable through method dispatch.
# assert('Array#+', '15.2.12.5.1') do
#   assert_equal([1, 1], [1].+([1]))
# end

# --- BLOCKED: Array#* (repeat-into-a-new-array, or join-with-string
# when given a String argument) doesn't exist at any level — no
# ValueOps.op case, no native method. Real gap, not just a dot-call
# syntax issue like +/<< below.
# assert('Array#*', '15.2.12.5.2') do
#   assert_raise(ArgumentError) do
#     # this will cause an exception due to the wrong argument
#     [1].*(-1)
#   end
#   assert_equal([1, 1, 1], [1].*(3))
#   assert_equal([], [1].*(0))
#   assert_equal('abc', ['a', 'b', 'c'].*(''))
#   assert_equal('0, 0, 1, {foo: 0}', [0, [0, 1], {foo: 0}].*(', '))
# end

# --- BLOCKED: same dot-call-vs-opcode gap as `+` above — infix
# `arr << 1` already works (ValueOps.shl), but `.<<(...)` isn't
# reachable through method dispatch.
# assert('Array#<<', '15.2.12.5.3') do
#   assert_equal([1, 1], [1].<<(1))
# end

# --- BLOCKED: `[]` is opcode-only (Op::GetIndex), so the dot-call
# form (`.[](...)`) used throughout this test isn't reachable via
# method dispatch. Separately, even the bracket syntax only supports a
# single Integer index — no two-arg (start, length) slicing, no Range
# indexing (`a[1..-2]`, `a[1..]`, `a[..2]`), no Float index coercion —
# see exec_get_index (vm.cr).
# assert('Array#[]', '15.2.12.5.4') do
#   a = Array.new
#   assert_raise(ArgumentError) do
#     # this will cause an exception due to the wrong arguments
#     a.[]()
#   end
#   assert_raise(ArgumentError) do
#     # this will cause an exception due to the wrong arguments
#     a.[](1,2,3)
#   end

#   assert_equal(2, [1,2,3].[](1))
#   assert_equal(nil, [1,2,3].[](4))
#   assert_equal(3, [1,2,3].[](-1))
#   assert_equal(nil, [1,2,3].[](-4))

#   a = [ "a", "b", "c", "d", "e" ]
#   assert_equal(["b", "c"], a[1,2])
#   assert_equal(["b", "c", "d"], a[1..-2])
#   assert_equal(["b", "c", "d", "e"], a[1..])
#   assert_equal(["a", "b", "c"], a[..2])
#   skip unless Object.const_defined?(:Float)
#   assert_equal("b", a[1.1])
# end

# --- BLOCKED: same `[]=` dot-call gap as `[]` above, plus range-based
# assignment (`a[3..-1] = ...`, `a[2...] = ...`), FrozenError, and
# self-referencing-source assignment — none of which exist.
# assert('Array#[]=', '15.2.12.5.5') do
#   a = Array.new
#   assert_raise(ArgumentError) do
#     # this will cause an exception due to the wrong arguments
#     a.[]=()
#   end
#   assert_raise(ArgumentError) do
#     # this will cause an exception due to the wrong arguments
#     a.[]=(1,2,3,4)
#   end
#   assert_raise(IndexError) do
#     # this will cause an exception due to the wrong arguments
#     a = [1,2,3,4,5]
#     a[1, -1] = 10
#   end

#   assert_equal(4, [1,2,3].[]=(1,4))
#   assert_equal(3, [1,2,3].[]=(1,2,3))

#   a = [1,2,3,4,5]
#   a[3..-1] = 6
#   assert_equal([1,2,3,6], a)

#   a = [1,2,3,4,5]
#   a[3..-1] = []
#   assert_equal([1,2,3], a)

#   a = [1,2,3,4,5]
#   a[2...4] = 6
#   assert_equal([1,2,6,5], a)

#   a = [1,2,3,4,5]
#   a[2...] = 6
#   assert_equal([1,2,6], a)

#   # passing self (#3274)
#   a = [1,2,3]
#   a[1,0] = a
#   assert_equal([1,1,2,3,2,3], a)
#   a = [1,2,3]
#   a[-1,0] = a
#   assert_equal([1,2,1,2,3,3], a)

#   # passing self with length above ARY_REPLACE_SHARED_MIN (=20).
#   # ary_dup -> ary_replace converts the source to shared as a
#   # copy-on-write optimization; without re-modifying `a` afterwards,
#   # ARY_CAPA(a) reads from aux.shared's pointer bits and the
#   # expand-capa check silently mis-sizes -> heap-buffer-overflow in
#   # value_move. Reported via clusterfuzz mruby_fuzzer.
#   a = (0..30).to_a
#   a[3, 2] = a
#   assert_equal(60, a.length)
#   assert_equal([0, 1, 2] + (0..30).to_a + (5..30).to_a, a)
# end

# --- BLOCKED: Array#clear doesn't exist (no mutating clear-in-place
# method registered).
# assert('Array#clear', '15.2.12.5.6') do
#   a = [1]
#   a.clear
#   assert_equal([], a)
# end

# --- BLOCKED: Array#collect! (the in-place/mutating counterpart to
# the already-implemented, non-mutating #map) doesn't exist.
# assert('Array#collect!', '15.2.12.5.7') do
#   a = [1,2,3]
#   a.collect! { |i| i + i }
#   assert_equal([2,4,6], a)
# end

# --- BLOCKED: Array#concat doesn't exist.
# assert('Array#concat', '15.2.12.5.8') do
#   assert_equal([1,2,3,4], [1, 2].concat([3, 4]))

#   # passing self (#3302)
#   a = [1,2,3]
#   a.concat(a)
#   assert_equal([1,2,3,1,2,3], a)
# end

# --- BLOCKED: Array#delete_at doesn't exist.
# assert('Array#delete_at', '15.2.12.5.9') do
#   a = [1,2,3]
#   assert_equal(2, a.delete_at(1))
#   assert_equal([1,3], a)
#   assert_equal(nil, a.delete_at(3))
#   assert_equal([1,3], a)
#   assert_equal(nil, a.delete_at(-3))
#   assert_equal([1,3], a)
#   assert_equal(3, a.delete_at(-1))
#   assert_equal([1], a)
# end

assert('Array#each', '15.2.12.5.10') do
  a = [1,2,3]
  b = 0
  a.each {|i| b += i}
  assert_equal(6, b)
end

# --- BLOCKED: Array#each_index doesn't exist.
# assert('Array#each_index', '15.2.12.5.11') do
#   a = [1]
#   b = nil
#   a.each_index {|i| b = i}
#   assert_equal(0, b)
# end

# --- Trimmed: the original test's `b = [b]` line is a vestigial,
# unused local (never referenced by the assertions themselves) that
# depends on real Ruby's "a local is declared at parse time, reads as
# nil before its own assignment completes" quirk — dropped rather than
# relied on, since it adds risk for zero test coverage.
assert('Array#empty?', '15.2.12.5.12') do
  assert_true([].empty?)
  assert_false([1].empty?)
end

# --- Original ISO test's out-of-range (Bignum) ArgumentError and
# multiple-arguments ArgumentError aren't implemented — native
# methods here don't arity-check their own argument count, so passing
# extra args is silently ignored rather than raising, and there's no
# Bignum type to construct an out-of-range count with in the first
# place. The count-argument form itself now works for real
# (`array.cr`, 2026-08-19 — see SCOPE.md/git history), so those
# assertions are uncommented below; the two ArgumentError cases stay
# out, a real, separate gap if ever wanted.
assert('Array#first', '15.2.12.5.13') do
  assert_nil([].first)

  b = [1,2,3]
  assert_equal(1, b.first)
  assert_equal([1,2], b.first(2))
  assert_equal([1,2,3], b.first(10))
  assert_equal([], b.first(0))
  assert_equal([], [].first(2))
end

# --- BLOCKED: Array#index doesn't exist.
# assert('Array#index', '15.2.12.5.14') do
#   a = [1,2,3]

#   assert_equal(1, a.index(2))
#   assert_equal(nil, a.index(0))
# end

# assert("Array#index (block)") do
#   assert_nil (1..10).to_a.index { |i| i % 5 == 0 and i % 7 == 0 }
#   assert_equal 34, (1..100).to_a.index { |i| i % 5 == 0 and i % 7 == 0 }
# end

# --- BLOCKED: `__send__` is deliberately excluded (U005 —
# send/method_missing/define_method family), so this test can't even
# reach `initialize` this way regardless of whether Array#initialize
# itself would otherwise work.
# assert('Array#initialize', '15.2.12.5.15') do
#   a = [].__send__(:initialize,1)
#   b = [].__send__(:initialize,2)
#   c = [].__send__(:initialize,2, 1)
#   d = [].__send__(:initialize,2) {|i| i}

#   assert_equal([nil], a)
#   assert_equal([nil,nil], b)
#   assert_equal([1,1], c)
#   assert_equal([0,1], d)
# end

# --- BLOCKED: same `__send__` exclusion as #initialize above.
# assert('Array#initialize_copy', '15.2.12.5.16') do
#   a = [1,2,3]
#   b = [].__send__(:initialize_copy, a)

#   assert_equal([1,2,3], b)
# end

assert('Array#join', '15.2.12.5.17') do
  a = [1,2,3].join
  b = [1,2,3].join(',')

  assert_equal('123', a)
  assert_equal('1,2,3', b)
end

# --- BLOCKED: Array#join here renders each element via Value#to_s,
# not a real recursive flatten-and-join — a nested array element
# renders as its own inspect-ish string (e.g. "[2, 3]") rather than
# being flattened into the same separator-joined sequence real Ruby
# produces. An accuracy gap, not just a missing feature.
# assert('Array#join nested arrays') do
#   assert_equal('1-2-3-4', [1, [2, 3], 4].join('-'))
#   assert_equal('12345', [[1, 2], [3, [4, 5]]].join)
# end

# --- BLOCKED: no cycle detection at all — `a << a; a.join` would
# not raise ArgumentError the way real Ruby does, it would recurse
# through Value#to_s until the native stack overflows. Left
# commented rather than run, to avoid actually triggering that.
# assert('Array#join detects recursion') do
#   a = []
#   a << a
#   assert_raise(ArgumentError) { a.join }

#   x = []
#   y = []
#   x << y
#   y << x
#   assert_raise(ArgumentError) { x.join }
# end

# --- BLOCKED: relies on join being genuinely iterative over deep
# nesting (real Ruby's own point of this test); ours isn't structured
# to guarantee that, so this is left unverified rather than risking a
# native stack overflow in the test suite itself.
# assert('Array#join deeply nested array does not overflow the C stack') do
#   a = []
#   10000.times { a = [a] }
#   # join is iterative, so a deeply nested (non-cyclic) array must not overflow
#   # the native stack; every leaf here is empty, so the result is "".
#   assert_equal('', a.join)
# end

# --- Original ISO test needs a bad-argument ArgumentError/TypeError
# (a non-Integer count) — not validated here, same as Range#step's own
# convention (native_call_context.cr) for its `n` argument; a
# non-Integer count isn't checked and would fail differently (a raw
# Crystal cast error) rather than a clean ArgumentError/TypeError.
# The count-argument form itself now works for real (`array.cr`,
# 2026-08-19 — see SCOPE.md/git history), so those assertions are
# uncommented below.
assert('Array#last', '15.2.12.5.18') do
  a = [1,2,3]
  assert_equal(3, a.last)
  assert_nil([].last)
  assert_equal([2,3], a.last(2))
  assert_equal([1,2,3], a.last(10))
  assert_equal([], a.last(0))
  assert_equal([], [].last(2))
end

assert('Array#length', '15.2.12.5.19') do
  a = [1,2,3]

  assert_equal(3, a.length)
end

# --- BLOCKED: Array#map! (in-place/mutating counterpart to #map)
# doesn't exist.
# assert('Array#map!', '15.2.12.5.20') do
#   a = [1,2,3]
#   a.map! { |i| i + i }
#   assert_equal([2,4,6], a)
# end

# --- Original ISO test's last line needs FrozenError/#freeze, neither
# of which exists (see SCOPE.md). Trimmed to the supported part.
assert('Array#pop', '15.2.12.5.21') do
  a = [1,2,3]
  b = a.pop

  assert_nil([].pop)
  assert_equal([1,2], a)
  assert_equal(3, b)
end

assert('Array#push', '15.2.12.5.22') do
  a = [1,2,3]
  b = a.push(4)

  assert_equal([1,2,3,4], a)
  assert_equal([1,2,3,4], b)
end

# --- BLOCKED: Array#replace doesn't exist.
# assert('Array#replace', '15.2.12.5.23') do
#   a = [1,2,3]
#   b = [].replace(a)

#   assert_equal([1,2,3], b)
# end

assert('Array#reverse', '15.2.12.5.24') do
  a = [1,2,3]
  b = a.reverse

  assert_equal([1,2,3], a)
  assert_equal([3,2,1], b)
end

# --- BLOCKED: Array#reverse! (in-place/mutating counterpart to the
# already-implemented, non-mutating #reverse) doesn't exist.
# assert('Array#reverse!', '15.2.12.5.25') do
#   a = [1,2,3]
#   b = a.reverse!

#   assert_equal([3,2,1], a)
#   assert_equal([3,2,1], b)
# end

# --- BLOCKED: Array#rindex doesn't exist.
# assert('Array#rindex', '15.2.12.5.26') do
#   a = [1,2,3]

#   assert_equal(1, a.rindex(2))
#   assert_equal(nil, a.rindex(0))
# end

# assert("Array#rindex (block)") do
#   assert_nil (1..10).to_a.rindex { |i| i % 5 == 0 and i % 7 == 0 }
#   assert_equal 69, (1..100).to_a.rindex { |i| i % 5 == 0 and i % 7 == 0 }
# end

# --- BLOCKED: Array#shift doesn't exist (neither the no-arg nor the
# arg-taking form), and FrozenError doesn't exist either.
# assert('Array#shift', '15.2.12.5.27') do
#   a = [1,2,3]
#   b = a.shift

#   assert_nil([].shift)
#   assert_equal([2,3], a)
#   assert_equal(1, b)

#   assert_raise(FrozenError) { [].freeze.shift }

#   # Array#shift with argument
#   assert_equal([], [].shift(1))

#   a = [1,2,3]
#   b = a.shift(1)
#   assert_equal([2,3], a)
#   assert_equal([1], b)

#   a = [1,2,3,4]
#   b = a.shift(3)
#   assert_equal([4], a)
#   assert_equal([1,2,3], b)

#   a = [1,2,3]
#   b = a.shift(4)
#   assert_equal([], a)
#   assert_equal([1,2,3], b)
# end

assert('Array#size', '15.2.12.5.28') do
  a = [1,2,3]

  assert_equal(3, a.size)
end

# --- BLOCKED: Array#slice doesn't exist at all (as distinct from the
# already-supported `[]` bracket syntax, which only takes a single
# Integer index anyway — see the `[]` block above for that gap).
# assert('Array#slice', '15.2.12.5.29') do
#   a = [*(1..100)]
#   b = a.dup

#   assert_equal(1, a.slice(0))
#   assert_equal(100, a.slice(99))
#   assert_nil(a.slice(100))
#   assert_equal(100, a.slice(-1))
#   assert_equal(99,  a.slice(-2))
#   assert_equal(1,   a.slice(-100))
#   assert_nil(a.slice(-101))
#   assert_equal([1],   a.slice(0,1))
#   assert_equal([100], a.slice(99,1))
#   assert_equal([],    a.slice(100,1))
#   assert_equal([100], a.slice(99,100))
#   assert_equal([100], a.slice(-1,1))
#   assert_equal([99],  a.slice(-2,1))
#   assert_equal([10, 11, 12], a.slice(9, 3))
#   assert_equal([10, 11, 12], a.slice(-91, 3))
#   assert_nil(a.slice(-101, 2))
#   assert_equal([1],   a.slice(0..0))
#   assert_equal([100], a.slice(99..99))
#   assert_equal([],    a.slice(100..100))
#   assert_equal([100], a.slice(99..200))
#   assert_equal([100], a.slice(-1..-1))
#   assert_equal([99],  a.slice(-2..-2))
#   assert_equal([10, 11, 12], a.slice(9..11))
#   assert_equal([10, 11, 12], a.slice(-91..-89))
#   assert_equal([10, 11, 12], a.slice(-91..-89))
#   assert_nil(a.slice(-101..-1))
#   assert_nil(a.slice(10, -3))
#   assert_equal([], a.slice(10..7))
#   assert_equal(b, a)
# end

# --- BLOCKED: Array#unshift doesn't exist.
# assert('Array#unshift', '15.2.12.5.30') do
#   a = [2,3]
#   b = a.unshift(1)
#   c = [2,3]
#   d = c.unshift(0, 1)

#   assert_equal([1,2,3], a)
#   assert_equal([1,2,3], b)
#   assert_equal([0,1,2,3], c)
#   assert_equal([0,1,2,3], d)
# end

# --- BLOCKED: no Array#inspect at all, and #to_s's actual rendering
# (Value#to_s's generic fallback, not a real Array-aware inspect) has
# no self-reference guard — `a[4] = a; a.to_s` would recurse until the
# native stack overflows rather than producing "[...]" like real Ruby.
# Left commented to avoid triggering that in the test suite itself.
# assert('Array#to_s', '15.2.12.5.31 / 15.2.12.5.32') do
#   a = [2, 3,   4, 5]
#   a[4] = a
#   r1 = a.to_s
#   r2 = a.inspect

#   assert_equal(r2, r1)
#   assert_equal("[2, 3, 4, 5, [...]]", r1)
# end

assert('Array#==', '15.2.12.5.33') do
  assert_false(["a", "c"] == ["a", "c", 7])
  assert_true(["a", "c", 7] == ["a", "c", 7])
  assert_false(["a", "c", 7] == ["a", "d", "f"])
end

# --- BLOCKED: neither Array#eql? nor Array#hash exist for any type
# (no exec_builtin case, no native method) — this isn't Array-specific.
# assert('Array#eql?', '15.2.12.5.34') do
#   a1 = [ 1, 2, 3 ]
#   a2 = [ 1, 2, 3 ]
#   a3 = [ 1.0, 2.0, 3.0 ]

#   assert_true(a1.eql? a2)
#   assert_false(a1.eql? a3)
# end

# --- BLOCKED: same #hash gap as #eql? above.
# assert('Array#hash', '15.2.12.5.35') do
#   a = [ 1, 2, 3 ]

#   assert_true(a.hash.is_a? Integer)
#   assert_equal([1,2].hash, [1,2].hash)
# end

# --- BLOCKED: ValueOps.spaceship (the `<=>` implementation) has no
# Array case, so `arr <=> other_arr` returns nil rather than a real
# sign — element-wise lexicographic comparison isn't implemented.
# assert('Array#<=>', '15.2.12.5.36') do
#   r1 = [ "a", "a", "c" ]    <=> [ "a", "b", "c" ]   #=> -1
#   r2 = [ 1, 2, 3, 4, 5, 6 ] <=> [ 1, 2 ]            #=> +1
#   r3 = [ "a", "b", "c" ]    <=> [ "a", "b", "c" ]   #=> 0

#   assert_equal(-1, r1)
#   assert_equal(+1, r2)
#   assert_equal(0, r3)
# end

# # Not ISO specified

# --- BLOCKED: needs Hash.new(default) (a default-value Hash, which
# isn't implemented — hash.cr has no singleton `new` override), used
# here for the `h[p.class] += 1` counting pattern.
# assert("Array (Longish inline array)") do
#   ary = [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4], [5, 5], [6, 6], [7, 7], [8, 8], [9, 9], [10, 10], [11, 11], [12, 12], [13, 13], [14, 14], [15, 15], [16, 16], [17, 17], [18, 18], [19, 19], [20, 20], [21, 21], [22, 22], [23, 23], [24, 24], [25, 25], [26, 26], [27, 27], [28, 28], [29, 29], [30, 30], [31, 31], [32, 32], [33, 33], [34, 34], [35, 35], [36, 36], [37, 37], [38, 38], [39, 39], [40, 40], [41, 41], [42, 42], [43, 43], [44, 44], [45, 45], [46, 46], [47, 47], [48, 48], [49, 49], [50, 50], [51, 51], [52, 52], [53, 53], [54, 54], [55, 55], [56, 56], [57, 57], [58, 58], [59, 59], [60, 60], [61, 61], [62, 62], [63, 63], [64, 64], [65, 65], [66, 66], [67, 67], [68, 68], [69, 69], [70, 70], [71, 71], [72, 72], [73, 73], [74, 74], [75, 75], [76, 76], [77, 77], [78, 78], [79, 79], [80, 80], [81, 81], [82, 82], [83, 83], [84, 84], [85, 85], [86, 86], [87, 87], [88, 88], [89, 89], [90, 90], [91, 91], [92, 92], [93, 93], [94, 94], [95, 95], [96, 96], [97, 97], [98, 98], [99, 99], [100, 100], [101, 101], [102, 102], [103, 103], [104, 104], [105, 105], [106, 106], [107, 107], [108, 108], [109, 109], [110, 110], [111, 111], [112, 112], [113, 113], [114, 114], [115, 115], [116, 116], [117, 117], [118, 118], [119, 119], [120, 120], [121, 121], [122, 122], [123, 123], [124, 124], [125, 125], [126, 126], [127, 127], [128, 128], [129, 129], [130, 130], [131, 131], [132, 132], [133, 133], [134, 134], [135, 135], [136, 136], [137, 137], [138, 138], [139, 139], [140, 140], [141, 141], [142, 142], [143, 143], [144, 144], [145, 145], [146, 146], [147, 147], [148, 148], [149, 149], [150, 150], [151, 151], [152, 152], [153, 153], [154, 154], [155, 155], [156, 156], [157, 157], [158, 158], [159, 159], [160, 160], [161, 161], [162, 162], [163, 163], [164, 164], [165, 165], [166, 166], [167, 167], [168, 168], [169, 169], [170, 170], [171, 171], [172, 172], [173, 173], [174, 174], [175, 175], [176, 176], [177, 177], [178, 178], [179, 179], [180, 180], [181, 181], [182, 182], [183, 183], [184, 184], [185, 185], [186, 186], [187, 187], [188, 188], [189, 189], [190, 190], [191, 191], [192, 192], [193, 193], [194, 194], [195, 195], [196, 196], [197, 197], [198, 198], [199, 199]]
#   h = Hash.new(0)
#   ary.each {|p| h[p.class] += 1}
#   assert_equal({Array=>200}, h)
# end

# --- BLOCKED: Array#rindex doesn't exist (see above).
# assert("Array#rindex") do
#   class Sneaky
#     def ==(*)
#       $a.clear
#       $a.replace([1])
#       false
#     end
#   end
#   $a = [2, 3, 4, 5, 6, 7, 8, 9, 10, Sneaky.new]
#   assert_equal 0, $a.rindex(1)
# end

# --- BLOCKED: Array#sort! (in-place/mutating counterpart to the
# already-implemented, non-mutating #sort) doesn't exist.
# assert('Array#sort!') do
#   a = [3, 2, 1]
#   assert_equal a, a.sort!      # sort! returns self.
#   assert_equal [1, 2, 3], a    # it is sorted.
# end

# --- BLOCKED: no #freeze, no FrozenError class.
# assert('Array#freeze') do
#   a = [].freeze
#   assert_raise(FrozenError) do
#     a[0] = 1
#   end
# end

# --- BLOCKED: Array#delete (delete-by-value, distinct from the
# missing #delete_at above) doesn't exist.
# assert('Array#delete') do
#   a = ["a", "b", "c"]
#   assert_equal nil, a.delete("x")
#   assert_equal "x", a.delete("x") { _1 }
#   assert_equal ["a", "b", "c"], a
#   assert_equal "a", a.delete("a")
#   assert_equal ["b", "c"], a

#   a = [nil]
#   assert_equal nil, a.delete(nil) { "?" }
#   assert_equal [], a
# end

# --- BLOCKED: needs #hash (doesn't exist) and self-referencing arrays.
# assert('Array#hash with self-referencing arrays') do
#   a = []
#   a << a
#   b = []
#   b << b
#   assert_equal a.hash, b.hash
# end
