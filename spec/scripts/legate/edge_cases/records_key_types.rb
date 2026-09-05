require "assert"

# `Legate.records`'s single sharpest judgment call (records.cr's own
# top comment): a `:jsonl` record's TOP-LEVEL JSON object keys are
# SYMBOLS (`record[:name]`), matching CSV's column-header-derived
# fields — deliberately DIFFERENT from `Legate::Response#json`'s
# general JSON decode, which keeps ordinary String keys. Nested Hash
# VALUES inside a jsonl record keep String keys — only the record's
# own top-level "columns" get symbolized, not arbitrary nested data.
# This distinction has no Ruby precedent to fall back on (real Ruby's
# `JSON.parse` doesn't do this at all — it's a Legate-specific
# convention), so it's exactly the kind of thing worth a script
# actually demonstrating rather than only documenting in a comment.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"

# --- jsonl: top-level keys are Symbols ---

events = Legate.records(FIXTURES / "events.jsonl", format: :jsonl).to_a
assert_equal("a", events[0][:name])
assert_equal(1, events[0][:n])

# --- jsonl: nested Hash values stay String-keyed ---

assert_equal("x", events[0][:meta]["nested"])
# Symbol access on a NESTED value's keys does NOT work — proving the
# distinction is real, not just "everything ends up a Symbol
# eventually." A String key and a Symbol key are different Values;
# `events[0][:meta][:nested]` would look up a key that was never
# actually stored (Hash#[] on a genuinely missing key returns nil,
# same as Ruby).
assert_nil(events[0][:meta][:nested])

# --- CSV, headers: true (the default): same Symbol-keyed shape ---
#
# Column headers become the record's Symbol keys — the SAME "one row,
# symbol-keyed fields" shape jsonl's own top level uses, deliberately
# unified (records.cr's own top comment) so a script processing
# either format doesn't need to remember which one uses which key
# type.
people = Legate.records(FIXTURES / "people.csv", format: :csv).to_a
assert_equal("alice", people[0][:name])
assert_equal("30", people[0][:age]) # CSV values are always Strings — "30", not 30

# --- CSV, headers: false: plain String-indexed Array instead ---
#
# No header row to derive Symbol keys FROM, so `headers: false` gives
# back an ordinary Array of Strings per row instead — a different
# shape from the Hash `headers: true` produces, not a Hash with
# numeric-String keys or anything trying to preserve the same
# interface.
raw_rows = Legate.records(FIXTURES / "people.csv", format: :csv, headers: false).to_a
assert_equal(["name", "age"], raw_rows[0]) # the header row is now just DATA, row 0
assert_equal(["alice", "30"], raw_rows[1])
