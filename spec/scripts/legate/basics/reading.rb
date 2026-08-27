require "assert"

# Legate's read-only verb slice, exercised end to end — both a
# regression test (via `assert`) and a living usage example, run by
# `src/test_runner.cr` the same way every other `spec/scripts/*.rb`
# file is. Reachable at all only because `_policy.yaml`, alongside
# this file, grants read access to `fixtures/` — see that file's own
# comment.
#
# `FIXTURES` is a real `Legate::Path`, not a hand-built string —
# `.parent` (this file's own directory) and `/` (join) are LEGATE.md
# §5.1's own path API, the same one `Legate.list`'s own Entries return
# (`entry.path`, used below). Every verb call below hands a `Path`
# object straight to `Legate.*` rather than calling `.to_s` first —
# every verb already accepts one directly (it calls `.to_s` on its own
# path argument internally, LEGATE.md §8's "every path argument
# becomes a Legate::Path at the boundary"), so there's nothing extra
# for a script to do.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"

# --- Legate.stat -----------------------------------------------------

hello_stat = Legate.stat(FIXTURES / "hello.txt")
assert("Legate.stat finds an existing file") { hello_stat.type == :file }
assert_equal(15, hello_stat.size) # "Hello, Legate!\n"

assert_nil(Legate.stat(FIXTURES / "does-not-exist.txt"))

# --- Legate.read -------------------------------------------------------

assert_equal("Hello, Legate!\n", Legate.read(FIXTURES / "hello.txt"))

assert_raise(Legate::NotFound) { Legate.read(FIXTURES / "does-not-exist.txt") }
assert_nothing_raised { Legate.read(FIXTURES / "does-not-exist.txt", missing: "fallback") }
assert_equal("fallback", Legate.read(FIXTURES / "does-not-exist.txt", missing: "fallback"))

# A path outside every granted root (`fixtures/` is granted, its
# PARENT is not) is a fatal Legate::Denied — LEGATE.md §2.3's own
# distinction from `Legate::NotFound` above. Deliberately NOT
# demonstrated with `assert_raise` here: `Legate::Denied` is a plain
# Crystal `Exception`, not `RuntimeError` (exceptions.cr's own
# comment on `FatalSignal` — "deliberately unrescuable by any script
# rescue"), so neither `assert_raise` nor an ordinary `rescue` in
# script code can catch it at all; attempting it here would crash
# this script's run rather than produce a clean assertion failure.
# That unrescuability IS the guarantee §2.3 describes — a script
# cannot swallow its way past a denied grant — so this comment is the
# accurate way to document the behavior without triggering it.

# --- Legate.list -------------------------------------------------------

# A plain interpolated STRING here, not `FIXTURES / "*"` — `*` is a
# glob wildcard for `Legate.list`'s own pattern argument, not a real
# path segment to join; forcing it through `Path#/` would be misusing
# an API meant for genuine path components. No `.sort` needed either
# — `Legate.list` already returns entries in the same sorted-by-path
# order `Dir.glob(...).sort` establishes internally (list.cr's own
# implementation) BEFORE building the Array a script sees.
words_and_events = Legate.list("#{FIXTURES}/*")
assert_equal(3, words_and_events.length)
names = words_and_events.map { |entry| entry.path.basename }
assert("Legate.list finds every fixture file") { names.include?("hello.txt") && names.include?("words.txt") && names.include?("events.jsonl") }

# --- Legate.lines --------------------------------------------------------

words = Legate.lines(FIXTURES / "words.txt").to_a
assert_equal(["alpha", "beta", "gamma"], words)

# --- Legate.bytes --------------------------------------------------------

first_chunk = Legate.bytes(FIXTURES / "hello.txt").to_a.first
assert_equal(15, first_chunk.size)

# --- Legate.records (jsonl) ----------------------------------------------

events = Legate.records(FIXTURES / "events.jsonl", format: :jsonl).to_a
assert_equal(2, events.length)
assert_equal(1, events[0][:n])
assert_equal("b", events[1][:label])

# --- Composition — the actual point of an end-to-end script over a
# per-verb unit spec: verbs feeding into each other, the way a real
# script would chain them.
#
# One line, not the more familiar multi-line leading-dot chain
# (`.select { }\n  .map { }\n  .to_a`) — that style is real Ruby 1.9+
# syntax but a KNOWN, already-tracked Adjutant parser gap (SCOPE.md's
# own "Leading-dot line continuation for a method chain isn't
# supported" entry), not something specific to this script. Worth
# knowing for anyone writing further example scripts in this
# directory: reach for one line (or an intermediate local variable
# per step) until that gap is closed.
labels = Legate.records(FIXTURES / "events.jsonl", format: :jsonl).select { |event| event[:n] > 1 }.map { |event| event[:label] }.to_a
assert_equal(["b"], labels)
