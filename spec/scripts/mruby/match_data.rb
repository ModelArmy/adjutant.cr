require "assert"

##
# MatchData Test
#
# Written fresh, NOT ported from upstream's `match_data.rb` — that
# file leans on `$~`/`$1`.. globals, `Regexp.last_match`, and IndexError
# semantics for a bad group name/index (Adjutant returns nil instead)
# in nearly every block, the same "pervasively unsupported"
# situation hash.rb's own header describes for its own history.
# Small and self-contained instead: real assertions for what
# `builtins/regexp.cr` actually implements today.
#
# `#named_captures`/`#names` and `Regexp.last_match` don't exist yet —
# real, worthwhile gaps, not filed as their own SCOPE.md entries yet.
# A bad group index/name returns `nil` rather than raising IndexError
# like real Ruby — a real, separate divergence, not covered here since
# there's no upstream block left to block it against; worth keeping in
# mind if this comes up again.

assert('MatchData#captures') do
  re = Regexp.new("(a)(b)(c)")
  md = re.match("abc")
  assert_equal ["a", "b", "c"], md.captures
end

assert('MatchData captures across alternation branches') do
  md = /(\d)|(x)/.match("1")
  assert_equal "1", md[1]
  assert_nil md[2]
  md = /(\d)|(x)/.match("x")
  assert_nil md[1]
  assert_equal "x", md[2]
  md = /(cat)|(dog)/.match("cat")
  assert_equal ["cat", nil], md.captures
end

assert('MatchData#pre_match / #post_match') do
  re = Regexp.new("bc")
  md = re.match("abcde")
  assert_equal "a", md.pre_match
  assert_equal "de", md.post_match
end

assert('MatchData#string') do
  md = Regexp.new("bc").match("abcde")
  assert_equal "abcde", md.string
end

assert('MatchData#regexp') do
  re = Regexp.new("bc")
  md = re.match("abcde")
  assert_equal re, md.regexp
end

assert('MatchData#to_s') do
  md = Regexp.new("bc").match("abcde")
  assert_equal "bc", md.to_s
end

assert('MatchData#begin / #end') do
  re = Regexp.new("bc")
  md = re.match("abcde")
  assert_equal 1, md.begin(0)
  assert_equal 3, md.end(0)
end

assert('MatchData#[] - indexed and named capture access') do
  md = /a(?<mid>b)c/.match("abc")
  assert_equal "abc", md[0]
  assert_equal "b", md[1]
  assert_equal "b", md[:mid]
  assert_equal "b", md["mid"]
end

assert('MatchData#[] - a group that did not participate is nil') do
  md = /(a)|(b)/.match("a")
  assert_equal "a", md[1]
  assert_nil md[2]
end
