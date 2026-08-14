require "assert"

##
# Regexp/MatchData Test
#
# Ported from mruby's mruby-regexp gem test file (no ISO section
# numbers in the original — Regexp isn't part of core ISO Ruby — so
# none are given here either, matching upstream). Faithful line-by-line
# port, not a rewrite: no shared harness class is involved (unlike
# hash.rb's own history), so triage-in-place is the right shape here.
#
# Three things worth knowing up front, since they block or shape a
# large fraction of the blocks below:
#
# 1. `assert_kind_of` ISN'T A REAL ADJUTANT FUNCTION — only the
#    assertions listed in `assert_module.cr`'s own doc comment exist
#    (`assert`, `assert_equal`, `assert_true`/`assert_false`, etc.).
#    Every ACTIVE (uncommented) `assert_kind_of X, y` from upstream is
#    rewritten in place to `assert_true y.is_a?(X)` — said once here
#    rather than re-noting it at every site, same as range.rb's own
#    header does for its own repeated caveats. BLOCKED sections below
#    keep `assert_kind_of` exactly as upstream wrote it, since nothing
#    there needs to actually run.
# 2. `$~`/`$1`.. GLOBALS DON'T EXIST AT ALL — no `$`-global plumbing in
#    Adjutant yet (see SCOPE.md's Regexp/MatchData entry). Blocks every
#    upstream assertion that reads or writes one.
# 3. INFIX `a =~ b` AND `a === b` DON'T PARSE — `=~` has no lexer
#    token at all (a real, tracked gap — see SCOPE.md's own `=~` entry,
#    filed the same session this file was written); `a === b` is a
#    DELIBERATE, permanent non-goal (UNSUPPORTED.md), not a gap —
#    `.===(x)` dot-call and `case/when` both work today and are NOT
#    blocked by this. Every upstream assertion using bare infix `=~`
#    or `===` is blocked for this reason; `.===`/`case`/`when` coverage
#    already exists at the Crystal-spec level (regexp_spec.cr) and
#    isn't re-proven here just to route around this gap.
#
# Beyond those three, several methods genuinely don't exist yet at
# all: block-form `#match`, `Regexp.escape`, `#inspect`/`#to_s`
# (the same to_s/inspect rendering gap already tracked in SCOPE.md for
# Array/Hash/Range, now also true for Regexp), `#==`/`#eql?`/`#hash`
# (the same cross-cutting eql?/hash gap from the original six-class
# survey handoff), and `Class#allocate`. And `#match`/`#match?` accept
# ONLY a String argument — no Symbol coercion, and a wrong-type
# argument raises ArgumentError (R022) rather than real Ruby's
# TypeError, a real, separate divergence from upstream's own
# expectations, not just a missing feature.

assert('Regexp.new with string') do
  re = Regexp.new("abc")
  assert_true re.is_a?(Regexp)
end

assert('Regexp.new with regexp') do
  r1 = Regexp.new("abc", Regexp::IGNORECASE)
  r2 = Regexp.new(r1)
  assert_equal r1.source, r2.source
  assert_equal r1.options, r2.options
  assert_true r2.match?("ABC")
end

assert('Regexp#match - simple') do
  re = Regexp.new("abc")
  md = re.match("xabcy")
  assert_true md.is_a?(MatchData)
  assert_equal "abc", md[0]
end

assert('Regexp#match - no match') do
  re = Regexp.new("xyz")
  assert_nil re.match("abc")
end

# --- BLOCKED: `$~` doesn't exist (see file header, point 2). Also a
# real, separate discrepancy, now cross-checked against a second
# upstream file: THIS file's own `Regexp#match(nil)` asserts nil is
# returned (real Ruby doesn't raise). But `string_regexp.rb` (a
# sibling test file in the same mruby-regexp gem) asserts
# `"abc".match(nil)` raises `TypeError` with the message "wrong
# argument type nil (expected Regexp)" — the opposite behavior, for
# the string-receiver form of the same operation. Possibly a genuine
# Regexp#match-vs-String#match difference in real Ruby; possibly the
# two upstream files drifted out of sync with each other over the
# gem's history. Either way, Adjutant currently raises
# ArgumentError/R022 for ANY non-String argument (nil included), which
# matches NEITHER file's own expectation exactly — left blocked rather
# than picking a side of an inconsistency neither source resolves.
# assert("Regexp#match - nil argument") do
#   $~ = /abc/.match("abc")
#   assert_nil /abc/.match(nil)
#   assert_nil $~
# end

# --- BLOCKED: block-form `#match` (yielding the MatchData to a block,
# with the block's return value becoming #match's own return value)
# isn't implemented — Regexp#match's native method never invokes a
# passed block at all right now. A real, worthwhile SCOPE.md candidate
# (not filed as its own entry yet — flagging here rather than
# silently skipping).
# assert("Regexp#match - block") do
#   result = /bc/.match("abcd") { |md| [md[0], md.begin(0)] }
#   assert_equal ["bc", 1], result
#   assert_nil(/xyz/.match("abcd") { |md| md[0] })
# end
# assert("Regexp#match - break out of the block") do
#   assert_equal :broke, /l+/.match("hello") { break :broke }
# end

assert('Regexp#match?') do
  re = Regexp.new("abc")
  assert_true re.match?("xabcy")
  assert_false re.match?("xyz")
  # --- BLOCKED: `match?(nil)` raises ArgumentError/R022 here rather
  # than returning false like upstream expects — same non-String-arg
  # divergence noted in the file header and above `#match - nil
  # argument`, not repeated as its own block.
  # assert_false re.match?(nil)
end

# --- BLOCKED: entirely dependent on `$~` (file header, point 2).
# assert("Regexp#match? - does not update last match") do
#   $~ = /matched/.match("matched")
#   assert_true /abc/.match?("abc")
#   assert_equal "matched", $~[0]
#   assert_false /xyz/.match?("abc")
#   assert_equal "matched", $~[0]
# end

# --- BLOCKED: infix `=~` doesn't parse at all (file header, point 3).
# assert("Regexp#=~") do
#   re = Regexp.new("bc")
#   assert_equal 1, re =~ "abcd"
#   assert_nil re =~ "xyz"
#   assert_equal __ENCODING__ == "UTF-8" ? 1 : 3, /い/ =~ "あい"
# end
# assert("Regexp#=~ - nil argument clears last match") do
#   $~ = /abc/.match("abc")
#   assert_nil(/abc/ =~ nil)
#   assert_nil $~
# end

# --- BLOCKED: infix `===` is a deliberate non-goal, and `$1` doesn't
# exist either (file header, points 2 and 3). `.===(x)` dot-call and
# case/when coverage already exists at the Crystal-spec level
# (regexp_spec.cr) rather than re-proven here as a rewrite.
# assert("Regexp#===") do
#   re = Regexp.new("abc")
#   assert_true re === "abc"
#   assert_false re === "xyz"
#   re = Regexp.new("hello (theo)")
#   assert_true re === "hello theo"
#   assert_equal "theo", $1
# end

# --- BLOCKED: Symbol arguments to #match/#match?/=~/=== aren't
# accepted — Adjutant requires a String outright (see file header).
# Cross-checked against a second upstream file: THIS file's own
# `Regexp#match(:xaby)` works and returns a real MatchData, but
# `string_regexp.rb` (a sibling file in the same gem) asserts
# `"abc".match(:b)` raises TypeError ("wrong argument type Symbol
# (expected Regexp)") for the string-receiver form — real Ruby itself
# rejecting Symbol there, not an mruby extension being tested. Same
# open question as the nil-argument block above: a genuine
# Regexp#match-vs-String#match asymmetry, or the two files drifted out
# of sync with each other. Blocked regardless, since Adjutant's own
# String-only requirement is settled either way (see
# string_pattern_arg's own String-first scoping, builtins/string.cr,
# for the same principle applied to String's own pattern-taking
# methods).
# assert("Regexp#match - Symbol argument") do
#   md = /a(b)/.match(:xaby)
#   assert_kind_of MatchData, md
#   assert_equal "ab", md[0]
#   assert_equal "b", md[1]
#   assert_equal "xaby", md.string
#   assert_equal "x", md.pre_match
#   assert_equal "ab", $~[0]
#   assert_equal "b", /(?<x>b)/.match(:ab)[:x]
#   assert_equal "A", (/a/.match(:ab) { |m| m[0].upcase })
#   assert_nil /z/.match(:ab)
# end
# assert("Regexp#match - Symbol argument with pos") do
#   assert_equal 3, /a/.match(:abxay, 1).begin(0)
#   assert_nil /a/.match(:ab, 2)
# end
# assert("Regexp#match - multibyte Symbol argument") do
#   # a multibyte name never fits the inline symbol representation, so this is
#   # the shared-buffer path, with a subject the offset conversion has to walk
#   assert_equal "い", /(い)/.match(:あいう)[1]
#   assert_equal __ENCODING__ == "UTF-8" ? 1 : 3, /い/ =~ :あい
#   assert_true /う/.match?(:あいう, 2)
#   assert_false /あ/.match?(:あいう, 1)
#   assert_true(/^あ/ === :あい)
# end
# assert("Regexp#match - Symbol argument does not alias the symbol table") do
#   # A symbol long enough to miss the inline representation shares the symbol
#   # table's buffer, and a dup keeps sharing it, so a destructive update has to
#   # copy first.
#   s = /a/.match(:abcdefghijklmnop).string.dup
#   s << "Z"
#   assert_equal "abcdefghijklmnopZ", s
#   assert_equal "abcdefghijklmnop", :abcdefghijklmnop.to_s
# end
# assert("Regexp#match? - Symbol argument") do
#   assert_true /a/.match?(:ab)
#   assert_false /z/.match?(:ab)
#   assert_false /a/.match?(:ab, 1)
#   assert_true /b/.match?(:ab, 1)
# end
# assert("Regexp#=~ - Symbol argument") do
#   assert_equal 1, (/b/ =~ :ab)
#   assert_equal "b", $~[0]
#   assert_nil(/z/ =~ :ab)
#   assert_nil $~
# end
# assert("Regexp#=== - Symbol argument") do
#   assert_true(/^to_/ === :to_s)
#   assert_false(/^to_/ === :size)
#   # Enumerable#grep is the motivating case: it dispatches through #===, so it
#   # used to answer [] rather than raise
#   assert_equal %i[to_s to_i], %i[to_s to_i size].grep(/^to_/)
#   result = case :hello123
#            when /\d+/ then "has digits"
#            else "no digits"
#            end
#   assert_equal "has digits", result
# end

# --- BLOCKED, real finding worth keeping visible: real Ruby raises
# TypeError for a non-String/non-Regexp #match/#match?/=~ argument;
# Adjutant raises ArgumentError/R022 instead (see file header) — a
# genuine error-class divergence, not just a missing feature. The
# last three lines are additionally blocked by infix `===`/`=~` not
# parsing at all (point 3 in the header) regardless of the error-class
# question.
# assert("Regexp - match operand rejects other types") do
#   assert_raise(TypeError) { /a/.match(1) }
#   assert_raise(TypeError) { /a/.match?(1) }
#   assert_raise(TypeError) { /a/ =~ 1 }
#   # #=== answers false rather than raising, for symbols and everything else
#   assert_false(/a/ === 1)
#   assert_false(/a/ === Object.new)
#   assert_false(/a/ === nil)
# end

# --- BLOCKED: `Regexp.escape` isn't implemented — no such class
# method registered at all. A real, worthwhile SCOPE.md candidate
# (commonly needed for building a pattern from untrusted/dynamic text
# safely) — not filed as its own entry yet; flagging here rather than
# silently skipping.
# assert("Regexp.escape") do
#   assert_equal "a\\.b\\*c", Regexp.escape("a.b*c")
#
#   # characters that are only special under the x flag or inside [...]
#   assert_equal "a\\ b", Regexp.escape("a b")
#   assert_equal "a\\#b", Regexp.escape("a#b")
#   assert_equal "a\\-b", Regexp.escape("a-b")
#
#   # control characters become printable two-character escapes
#   assert_equal "a\\nb", Regexp.escape("a\nb")
#   assert_equal "a\\tb", Regexp.escape("a\tb")
#   assert_equal "a\\rb", Regexp.escape("a\rb")
#   assert_equal "a\\fb", Regexp.escape("a\fb")
#   assert_equal "a\\vb", Regexp.escape("a\vb")
#
#   # non-ASCII bytes pass through untouched
#   assert_equal "あ\\-い", Regexp.escape("あ-い")
#
#   # the escaped pattern matches the original literally in every mode
#   [" ", "#", "-", "\n", "\t", "\r", "\f", "\v"].each do |c|
#     src = Regexp.escape(c)
#     assert_true Regexp.new(src).match?(c)
#     assert_true Regexp.new(src, Regexp::EXTENDED).match?(c)
#   end
#   assert_true Regexp.new(Regexp.escape("a b"), Regexp::EXTENDED).match?("a b")
#   assert_true Regexp.new(Regexp.escape("a # b"), Regexp::EXTENDED).match?("a # b")
# end

# --- BLOCKED: `#inspect` doesn't exist on Regexp — the same to_s/
# inspect rendering gap already tracked in SCOPE.md (originally filed
# against Array/Hash/Range), now also true for Regexp.
# assert("Regexp#inspect") do
#   re = Regexp.new("abc", Regexp::IGNORECASE)
#   assert_equal "/abc/i", re.inspect
#   # several flags are written in the m, i, x order, whatever order they
#   # were given in
#   assert_equal "/abc/mi", Regexp.new("abc", Regexp::IGNORECASE | Regexp::MULTILINE).inspect
#   assert_equal "/abc/mix", Regexp.new("abc", Regexp::IGNORECASE | Regexp::MULTILINE | Regexp::EXTENDED).inspect
# end

# --- BLOCKED: `#to_s` doesn't exist on Regexp either — same gap as
# #inspect above, not a separate one.
# assert("Regexp#to_s") do
#   assert_equal "(?-mix:abc)", Regexp.new("abc").to_s
#   assert_equal "(?i-mx:abc)", Regexp.new("abc", Regexp::IGNORECASE).to_s
#   assert_equal "(?m-ix:abc)", Regexp.new("abc", Regexp::MULTILINE).to_s
#   assert_equal "(?mi-x:abc)", Regexp.new("abc", Regexp::IGNORECASE | Regexp::MULTILINE).to_s
#   # the '-' run is dropped only when no flag is off
#   assert_equal "(?mix:abc)", Regexp.new("abc", Regexp::IGNORECASE | Regexp::MULTILINE | Regexp::EXTENDED).to_s
#
#   # the form recompiles, and the flags it names do not leak either way
#   assert_true Regexp.new(Regexp.new("abc", Regexp::IGNORECASE).to_s).match?("ABC")
#   assert_false Regexp.new(Regexp.new("abc").to_s + "d", Regexp::IGNORECASE).match?("ABCd")
# end

# --- BLOCKED: same #to_s gap as directly above — NOT a general
# interpolation problem (regex-literal interpolation of an ordinary
# String expression works fine, see the active "Regexp literal"
# coverage further down and regexp_spec.cr's own interpolation
# coverage) — specifically, interpolating a Regexp OBJECT depends on
# ITS #to_s rendering as "(?flags-offflags:pattern)" so the
# interpolated sub-pattern carries its own flags correctly, which
# doesn't exist yet.
# assert("Regexp#to_s - interpolation") do
#   inner = Regexp.new("abc", Regexp::IGNORECASE)
#   # the inner Regexp keeps its own flags where the outer has none
#   assert_true(/#{inner}d/.match?("ABCd"))
#   assert_false(/#{inner}d/.match?("ABCD"))
#   # and does not pick up the outer ones
#   assert_false(/#{Regexp.new("abc")}d/i.match?("ABCd"))
# end

# --- BLOCKED: `#==`/`#eql?` don't exist on Regexp — falls through to
# identity comparison, so even two separately-constructed Regexps with
# identical source/options would compare unequal. The same category
# of content-equality gap this project already found and fixed once
# for Range#== (see DEVELOPMENT.md) — not yet applied here.
# assert("Regexp#== and Regexp#eql?") do
#   r1 = Regexp.new("abc", Regexp::IGNORECASE)
#   r2 = Regexp.new("abc", Regexp::IGNORECASE)
#   r3 = Regexp.new("abc")
#   r4 = Regexp.new("def", Regexp::IGNORECASE)
#   assert_true r1 == r2
#   assert_true r1.eql?(r2)
#   assert_false r1 == r3       # different flags
#   assert_false r1 == r4       # different source
#   assert_false r1 == "abc"    # not a Regexp
# end

# --- BLOCKED: `#hash` doesn't exist on Regexp — same cross-cutting
# "eql?/hash not existing for any type" gap already tracked in
# SCOPE.md from the original six-class survey handoff, not a
# Regexp-specific finding.
# assert("Regexp#hash") do
#   r1 = Regexp.new("abc", Regexp::IGNORECASE)
#   r2 = Regexp.new("abc", Regexp::IGNORECASE)
#   r3 = Regexp.new("abc")
#   assert_equal r1.hash, r2.hash
#   assert_not_equal r1.hash, r3.hash
# end

# --- BLOCKED: `Class#allocate` isn't implemented at all (no native
# method registered for it on any class), on top of the #==/#hash
# gaps immediately above.
# assert("Regexp#hash/== on uninitialized regexp") do
#   # Regexp.allocate yields an object with no @source IV; hash/== must
#   # not crash (regression: ObjectSpace.each_object could expose a
#   # half-initialized Regexp after Regexp.new raised a compile error).
#   r = Regexp.allocate
#   assert_kind_of Integer, r.hash
#   assert_true r == r
#   assert_false r == Regexp.allocate
#   assert_false r == Regexp.new("abc")
# end

assert('Regexp#options') do
  assert_equal 0, Regexp.new("abc").options
  assert_equal Regexp::IGNORECASE, Regexp.new("abc", Regexp::IGNORECASE).options
  assert_equal Regexp::MULTILINE, Regexp.new("abc", Regexp::MULTILINE).options
  assert_equal Regexp::EXTENDED, Regexp.new("abc", Regexp::EXTENDED).options
  # Parenthesized here (not upstream's own bare multi-line form) —
  # bare/paren-less calls don't support a trailing `,` continuing the
  # argument list onto the next line yet, a real Must Fix filed in
  # SCOPE.md the same session this was found; wrapping in parens (the
  # OTHER call-args path, which already handles this correctly)
  # sidesteps it rather than papering over it silently.
  assert_equal(Regexp::IGNORECASE | Regexp::MULTILINE,
               Regexp.new("abc", Regexp::IGNORECASE | Regexp::MULTILINE).options)
  assert_equal(Regexp::IGNORECASE | Regexp::EXTENDED | Regexp::MULTILINE,
               Regexp.new("abc", Regexp::IGNORECASE | Regexp::EXTENDED | Regexp::MULTILINE).options)
end

assert('Regexp#casefold?') do
  assert_true Regexp.new("abc", Regexp::IGNORECASE).casefold?
  assert_false Regexp.new("abc").casefold?
end

assert('Regexp literal /regex/') do
  assert_true /abc/.match?("abc")
  assert_equal "123", /\d+/.match("abc123")[0]
  assert_true /hello/i.match?("HELLO")
end
