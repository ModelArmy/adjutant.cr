require "assert"

# `Legate.grep`'s own rich feature set (LEGATE.md §4.1) — regex vs
# literal patterns, `context:`, an Array mixing literal files and
# globs, and binary-file skipping — none of it exercised by any
# script until now (only its `limit:`/`TooMany` behavior was, in
# edge_cases/error_paths.rb). No Ruby precedent for any of grep.cr's
# own judgment calls here either (the binary-skip heuristic, the
# String-vs-Regexp pattern split, the context-window shape) — worth
# demonstrating concretely, not just asserting from grep_spec.cr.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"

# --- A Regexp pattern, not just a literal String ---
#
# app.txt (see fixtures/app.txt — named .txt, not .rb, deliberately:
# a .rb fixture would get picked up and RUN by test_runner.cr's own
# `**/*.rb` glob, not just read as grep content) has two lines
# matching `/TODO.*\d+/` — `grep` is LINE-based (each line matched
# independently), not multiline, so this proves the Regexp itself
# works end to end through grep, not just through the language's own
# regex engine.
todo_matches = Legate.grep(/TODO.*\d+/, FIXTURES / "app.txt").map { |m| m.text }
assert_equal(2, todo_matches.length)
assert("both TODO lines matched, in file order") do
  todo_matches[0].include?("fix this bug") && todo_matches[1].include?("another one")
end

# --- context: — before/after are the actual surrounding lines ---

target = Legate.grep("TARGET", FIXTURES / "notes.txt", context: 2).first
assert_equal(["first line", "second line"], target.before)
assert_equal(["fourth line", "fifth line"], target.after)
assert_equal(3, target.line_no)

# --- paths as an Array, mixing literal files (not just globs) ---
#
# Both `app.txt` (2 "TODO" lines) and `notes.txt` (1 "TODO" line)
# contribute matches — proving EVERY element of the Array was
# actually searched, not just the first.
mixed = Legate.grep("TODO", [FIXTURES / "app.txt", FIXTURES / "notes.txt"])
assert_equal(3, mixed.length)
basenames = mixed.map { |m| m.path.basename }
assert("matches came from both files, not just one") do
  basenames.include?("app.txt") && basenames.include?("notes.txt")
end

# --- Binary files are skipped, even when their TEXT would match ---
#
# `data.bin` literally contains the word "binary" as text (see
# fixtures/data.bin) — if binary-skipping weren't working, THIS is
# exactly the file that would wrongly show up. It's excluded purely
# because of the NUL byte elsewhere in the file (grep.cr's own git-
# style heuristic), unrelated to whether its text would otherwise
# match.
assert_equal(0, Legate.grep("binary", "#{FIXTURES}/*").length)
