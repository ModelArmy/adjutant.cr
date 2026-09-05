require "assert"

# Legate's single-pass Stream contract (LEGATE.md §6.1) — the part of
# the read-verb surface that's easiest to get wrong without a script
# actually demonstrating it, since there's no upstream Ruby
# `Enumerator` behavior to fall back on for intuition here. Two
# genuinely different things are both true and easy to conflate:
#
#   1. Once a stream's underlying SOURCE is physically exhausted
#      (walked all the way to the end), any FURTHER terminal call
#      raises `Legate::EOF` — the stream doesn't silently restart.
#   2. A PARTIAL walk (e.g. one `.first` call) does NOT exhaust the
#      source — a later terminal on the SAME stream value continues
#      from where the first one left off, it does not raise EOF and
#      does not restart from the beginning either.
#
# (1) is the documented rule; (2) is a natural consequence of how
# streams are actually implemented (stream.cr's own `StreamConsumption`
# is a shared, mutable reference every derived/terminal call on the
# same stream value sees), not separately spelled out in LEGATE.md's
# prose — worth a script proving it holds, not just inferring it from
# reading the implementation.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"

# --- Full exhaustion -> Legate::EOF, across all three stream verbs ---

lines_stream = Legate.lines(FIXTURES / "words.txt")
assert_equal(["alpha", "beta", "gamma"], lines_stream.to_a)
assert_raise(Legate::EOF) { lines_stream.to_a }

bytes_stream = Legate.bytes(FIXTURES / "hello.txt")
bytes_stream.to_a
assert_raise(Legate::EOF) { bytes_stream.to_a }

records_stream = Legate.records(FIXTURES / "events.jsonl", format: :jsonl)
assert_equal(2, records_stream.to_a.length)
assert_raise(Legate::EOF) { records_stream.to_a }

# --- A chained (.select/.map) stream shares EOF with its source ---
#
# `.select`/`.map` build a NEW stream value wrapping the SAME
# underlying source (stream.cr's own `chain` — a new StreamObject,
# but `obj.state` is passed through, not copied) — so walking the
# CHAINED stream to exhaustion marks the ORIGINAL stream exhausted
# too, and vice versa; they're two views onto one shared cursor, not
# two independent streams.
base = Legate.lines(FIXTURES / "words.txt")
chained = base.select { |l| l.length > 4 }
assert_equal(["alpha", "gamma"], chained.to_a) # "beta" (length 4) is the only one excluded
assert_raise(Legate::EOF) { base.to_a }

# --- A PARTIAL walk does NOT exhaust the source ---

partial = Legate.lines(FIXTURES / "words.txt")
assert_equal("alpha", partial.first)
# Continues from "beta" — does NOT restart from "alpha", does NOT
# raise EOF (the source isn't exhausted, just partway through).
assert_equal(["beta", "gamma"], partial.to_a)
# NOW it's exhausted, having reached the end via the .to_a above.
assert_raise(Legate::EOF) { partial.to_a }
