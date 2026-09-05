require "assert"

# Rounding out coverage for behaviors none of the earlier scripts
# (basics/, edge_cases/, grep_deep_dive/) happened to exercise —
# `Legate.bytes`' own `chunk:` kwarg, `Legate.read`'s own size-based
# `TooLarge` (distinct from `Legate.lines`' line-based cap — a
# DIFFERENT mechanism, already demonstrated, worth showing this one
# is real too, not just inherited), `Legate.records`' `Malformed` for
# BOTH formats, two `Legate.lines` edge shapes, and `Legate.list`'s
# recursive `**` glob plus its `Entry` fields.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"

# --- Legate.bytes: chunk: controls the actual chunk size ---
#
# `twenty_bytes.txt` is exactly 20 bytes — `chunk: 5` divides it into
# exactly 4 equal chunks; the DEFAULT chunk size (65_536) is far
# bigger than the whole file, so the same file yields exactly ONE
# chunk with no `chunk:` given at all. Same file, two different
# `chunk:` values, side by side — the clearest way to show `chunk:`
# is doing real work, not just present in the signature.
custom = Legate.bytes(FIXTURES / "twenty_bytes.txt", chunk: 5).to_a
assert_equal(4, custom.length)
assert("every custom chunk is exactly 5 bytes") { custom.all? { |c| c.size == 5 } }

default = Legate.bytes(FIXTURES / "twenty_bytes.txt").to_a
assert_equal(1, default.length)
assert_equal(20, default.first.size)

# --- Legate.read: its OWN size-based TooLarge (not lines' line cap) ---
#
# `big_for_read.txt` is 94 bytes; `limit: 10` makes even this small,
# ordinary file too large for `Legate.read` specifically — a
# different mechanism from `Legate.lines`' `max_line:` (already
# demonstrated in edge_cases/error_paths.rb): this one caps the WHOLE
# FILE's size, checked once via `File.info?`, not a per-line running
# buffer.
assert_raise(Legate::TooLarge) { Legate.read(FIXTURES / "big_for_read.txt", limit: 10) }

# --- Legate.records: Malformed for BOTH formats, not just one ---

assert_raise(Legate::Malformed) { Legate.records(FIXTURES / "bad.jsonl", format: :jsonl).to_a }
assert_raise(Legate::Malformed) { Legate.records(FIXTURES / "bad.csv", format: :csv).to_a }

# --- Legate.lines: two shapes worth pinning down explicitly ---

assert_equal([], Legate.lines(FIXTURES / "empty.txt").to_a)
# No trailing "\n" in the source file — the final line is still a
# real line, not silently dropped just because it has no terminator.
assert_equal(["one", "two"], Legate.lines(FIXTURES / "no_trailing_newline.txt").to_a)

# --- Legate.list: recursive ** glob, and inspecting Entry's fields ---
#
# `fixtures/tree/top.txt` and `fixtures/tree/nested/deep/file.txt` —
# `**` reaches the deeply-nested one too, not just direct children.
tree_entries = Legate.list("#{FIXTURES}/tree/**/*.txt")
assert_equal(2, tree_entries.length)
names = tree_entries.map { |e| e.path.basename }
assert("both the top-level and deeply-nested file were found") do
  names.include?("top.txt") && names.include?("file.txt")
end

first_entry = tree_entries.first
assert_equal(:file, first_entry.type)
assert("size reflects real file content") { first_entry.size > 0 }
assert("mtime is present") { first_entry.mtime }
