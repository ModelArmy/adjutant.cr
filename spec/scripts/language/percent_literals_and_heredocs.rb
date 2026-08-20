require "assert"

# `%w[]`/`%i[]` word/symbol array literals, and heredocs (`<<ID`,
# `<<-ID`, `<<~ID`, each optionally `'ID'`/`"ID"`-quoted) — SCOPE.md's
# top Must Fix entry as of 2026-08-19, promoted from Will Fix
# 2026-08-15. Neither existed before (no `Heredoc`/`%w` handling
# anywhere in lexer.cr/token.cr); both are lexer-level additions —
# `%w`/`%i` desugar into an ordinary ArrayLiteral once lexed, and a
# heredoc's body, once extracted, produces the SAME StringPart/.../
# StringEnd (or plain String) token shape an ordinary string literal
# already does, so no parser changes were needed for heredoc content
# itself.
#
# Scoped, documented limitations (see lexer.cr's own comments):
# - Only `%w`/`%i` are supported, not the interpolating `%W`/`%I`
#   forms, nor the general `%q`/`%Q`/`%r` literal forms.
# - Only ONE heredoc opener is supported per physical line — stacked
#   heredocs (`foo(<<~A, <<~B)`) aren't attempted here.

# --- %w[] / %i[] ---

assert("%w[] with bracket delimiters splits on whitespace into Strings") do
  %w[foo bar baz] == ["foo", "bar", "baz"]
end

assert("%i[] with bracket delimiters splits into Symbols") do
  %i[foo bar baz] == [:foo, :bar, :baz]
end

assert("%w[] collapses runs of whitespace, including newlines") do
  %w[
    one   two
    three
  ] == ["one", "two", "three"]
end

assert("%w[] with a backslash-escaped space keeps it as one word") do
  %w[foo\ bar baz] == ["foo bar", "baz"]
end

assert("%w[] with a backslash-escaped backslash decodes to one backslash") do
  %w[a\\b c] == ["a\\b", "c"]
end

assert("an empty %w[] is an empty Array") do
  %w[] == []
end

assert("%w() supports paren delimiters") do
  %w(a b c) == ["a", "b", "c"]
end

assert("%w{} supports brace delimiters") do
  %w{a b c} == ["a", "b", "c"]
end

assert("%w<> supports angle-bracket delimiters") do
  %w<a b c> == ["a", "b", "c"]
end

assert("%w|...| supports a same-char (non-nesting) delimiter") do
  %w|a b c| == ["a", "b", "c"]
end

assert("%w[] with bracket delimiters nests a literal inner bracket pair") do
  %w[a [b] c] == ["a", "[b]", "c"]
end

# --- heredocs: plain <<ID ---

assert("<<ID is a literal multi-line string, terminator flush left") do
  s = <<HERE
line one
line two
HERE
  s == "line one\nline two\n"
end

assert("<<ID interpolates #{} like a double-quoted string") do
  x = 21
  s = <<HERE
the answer is #{x * 2}
HERE
  s == "the answer is 42\n"
end

assert("<<ID processes backslash escapes like a double-quoted string") do
  s = <<HERE
a\tb
HERE
  s == "a\tb\n"
end

# --- heredocs: <<-ID (indented terminator, body not dedented) ---

assert("<<-ID allows an indented terminator without dedenting the body") do
  s = <<-HERE
    still indented
    HERE
  s == "    still indented\n"
end

# --- heredocs: <<~ID (squiggly, dedents to the least-indented line) ---

assert("<<~ID dedents the body to its least-indented line") do
  s = <<~HERE
    first
      second
    third
    HERE
  s == "first\n  second\nthird\n"
end

assert("<<~ID leaves a body with no common indentation unchanged") do
  s = <<~HERE
first
    second
  HERE
  s == "first\n    second\n"
end

# --- heredocs: quoting controls interpolation ---

assert("<<'ID' (single-quoted) is fully literal, no interpolation") do
  x = 1
  s = <<~'HERE'
    #{x} stays literal
    HERE
  s == "\#{x} stays literal\n"
end

assert("<<\"ID\" (double-quoted) interpolates, same as bare <<ID") do
  x = 5
  s = <<~"HERE"
    value: #{x}
    HERE
  s == "value: 5\n"
end

assert("<<'ID' does not process backslash escapes either") do
  s = <<~'HERE'
    a\tb
    HERE
  s == "a\\tb\n"
end

# --- heredocs: as part of a larger expression ---

assert("a heredoc can be used as an ordinary call argument") do
  def wrap(s)
    "[#{s.chomp}]"
  end
  wrap(<<~HERE) == "[wrapped]"
    wrapped
  HERE
end

assert("code after a heredoc opener on the same line still parses") do
  a = <<~HERE + "!"
    hi
  HERE
  a == "hi\n!"
end

assert("an empty heredoc body is an empty string") do
  s = <<~HERE
    HERE
  s == ""
end
