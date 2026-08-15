require "assert"

##
# String Regexp Integration Test
#
# Written fresh, NOT ported from upstream's `string_regexp.rb` — that
# file is built almost entirely around infrastructure Adjutant doesn't
# have at all: `$~`/`$1`.. globals; `assert_raise_with_message` (not a
# real Adjutant assert function — only plain `assert_raise` exists);
# `String#scan`; `String#sub!`/`#gsub!` (bang mutation methods);
# `Enumerator`; frozen strings/`FrozenError`; `String#b` and
# byte-vs-character encoding internals; and deep duck-typing edge
# cases (custom classes overriding `is_a?`/`class`, `to_str`
# coercion, `Regexp`/`String` subclassing) that test CRuby's exact
# type-checking machinery well past "does the feature work." The same
# "pervasively unsupported" situation hash.rb's own header describes
# for its own history — small and self-contained instead: real
# assertions for what `builtins/string.cr`'s Regexp integration
# actually implements today (see that file's own `string_pattern_arg`
# for the shared String-or-Regexp entry point `#index`/`#rindex`/
# `#sub`/`#gsub`/`#split` all go through).
#
# One real, worth-noting finding surfaced while reading upstream even
# though it isn't portable here: real Ruby raises `TypeError` (with an
# exact, informative message) for a non-String/non-Regexp pattern
# argument to `#match`/`#sub`/`#gsub`/`#scan`/`#split` — confirming
# what `regexp.rb`'s own header already flagged as a real divergence,
# not a hedge: Adjutant raises `ArgumentError`/R018/R019/R022 instead
# across the board, a real, separate, not-yet-addressed gap. `#scan`
# itself doesn't exist in Adjutant at all yet either — a real,
# worthwhile SCOPE.md candidate, not filed as its own entry yet.

assert('String#index with a Regexp pattern') do
  assert_equal 1, "abcabc".index(/b./)
end

assert('String#rindex with a Regexp pattern') do
  assert_equal 4, "abcabc".rindex(/b./)
end

assert('String#sub with a Regexp pattern') do
  assert_equal "hXllo", "hello".sub(/e/, "X")
end

assert('String#gsub with a Regexp pattern') do
  assert_equal "h-ll-", "hello".gsub(/[eo]/, "-")
end

assert('String#sub/#gsub - replacement string takes precedence over the block') do
  assert_equal "aXc", "abc".sub(/b/, "X") { "Y" }
  assert_equal "aXcX", "abcb".gsub(/b/, "X") { "Y" }
  assert_equal "aYc", "abc".sub(/b/) { "Y" }
  assert_equal "aYcY", "abcb".gsub(/b/) { "Y" }
end

assert('String#sub with backslash-reference specials') do
  assert_equal "a[bc]d", "abcd".sub(/bc/, "[\\&]")
  assert_equal "a[a]d", "abcd".sub(/bc/, "[\\`]")
  assert_equal "a[d]d", "abcd".sub(/bc/, "[\\']")
  assert_equal "a\\d", "abcd".sub(/bc/, "\\\\")
  assert_equal "abbd", "abcd".sub(/(b)c/, "\\1\\1")
end

assert('String#gsub with a block') do
  assert_equal "HELLO WORLD", "hello world".gsub(/\w+/) { |m| m.upcase }
end

assert('String#gsub date reformat, using capture groups from a block') do
  # Real Ruby's own version of this test reads $~ inside the block —
  # not available here (no $-global plumbing at all yet), so the
  # block re-matches the substring it's given instead, using
  # String#match (added alongside this file). A real workaround for a
  # real gap, not the natural way to write this in Ruby.
  result = "2026-03-21".gsub(/(\d+)-(\d+)-(\d+)/) { |m| md = /(\d+)-(\d+)-(\d+)/.match(m); "#{md[3]}/#{md[2]}/#{md[1]}" }
  assert_equal "21/03/2026", result
end

assert('String#split with a Regexp pattern') do
  assert_equal ["a", "b", "c"], "a, b, c".split(/,\s*/)
end

assert('String#split with a Regexp pattern and a limit') do
  # A limit of 1 means no splitting at all — the whole receiver comes
  # back as the single element, unsplit (this line's own expected
  # value was originally wrong here — ["a"] instead of ["a,"] — caught
  # by the same test run that caught the block-precedence bug above).
  assert_equal ["a,"], "a,".split(/,/, 1)
  assert_equal ["a,b,"], "a,b,".split(/,/, 1)
end

assert('String#split with an empty Regexp pattern') do
  assert_equal ["a", "b", "c"], "abc".split(//)
end

assert('String#match with a Regexp argument') do
  md = "hello world".match(Regexp.new("(\\w+)\\s(\\w+)"))
  assert_equal "hello", md[1]
  assert_equal "world", md[2]
end

assert('String#match - block yields a real MatchData, not just the substring') do
  assert_equal "L", "hello".match("l") { |md| md[0].upcase }
  assert_equal "ll", "hello".match("l+") { |md| md[0] }
  assert_nil("hello".match("z") { |md| md[0] })
end

assert('String#match - break out of the block') do
  assert_equal :broke, "hello".match("l+") { break :broke }
end
