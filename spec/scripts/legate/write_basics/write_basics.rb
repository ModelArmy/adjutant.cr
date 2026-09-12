require "assert"

# The `write` grant's four verbs (LEGATE.md §4.3), used the way a
# real script actually would — building up a small directory tree,
# not each verb in isolation. Byte counts below were verified with
# `wc -c` before writing, not computed by eye.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"
WORKSPACE = Legate::Path.new(__FILE__).parent / "workspace"

# --- Legate.mkdir: recursive, and idempotent (safe to call again) ---

Legate.mkdir(WORKSPACE)
assert_nothing_raised { Legate.mkdir(WORKSPACE) } # already exists — no error, per §4.3

nested = WORKSPACE / "reports" / "2026"
Legate.mkdir(nested) # every missing intermediate directory, in one call
assert("nested directory was actually created") { Legate.stat(nested).dir? }

# --- Legate.write: String, then Array of Strings ---

assert_equal(6, Legate.write(WORKSPACE / "notes.txt", "hello\n"))
assert_equal("hello\n", Legate.read(WORKSPACE / "notes.txt"))

assert_equal(6, Legate.write(WORKSPACE / "list.txt", ["a\n", "b\n", "c\n"]))
assert_equal("a\nb\nc\n", Legate.read(WORKSPACE / "list.txt"))

# --- Legate.append: adds to the end, doesn't overwrite ---

assert_equal(5, Legate.append(WORKSPACE / "notes.txt", "more\n"))
assert_equal("hello\nmore\n", Legate.read(WORKSPACE / "notes.txt"))

# --- Legate.write given a Legate STREAM — piped straight to disk ---
#
# `data` here is `Legate.lines(...).map { }` — a live stream, not an
# Array — so §4.3's "a pipeline never materialises merely to reach
# disk" is real here, not just a String/Array in disguise.
upper_bytes = Legate.write(WORKSPACE / "upper.txt", Legate.lines(FIXTURES / "source.txt").map { |l| l.upcase + "\n" })
assert_equal(17, upper_bytes)
assert_equal("ALPHA\nBETA\nGAMMA\n", Legate.read(WORKSPACE / "upper.txt"))

# --- Legate.cp: a plain file copy ---

Legate.cp(FIXTURES / "source.txt", WORKSPACE / "copy.txt")
assert_equal(Legate.read(FIXTURES / "source.txt"), Legate.read(WORKSPACE / "copy.txt"))

# --- Legate.cp: recursive: true for a whole directory tree ---

Legate.write(nested / "summary.txt", "2026 summary\n")
Legate.cp(nested, WORKSPACE / "reports_backup", recursive: true)
assert_equal("2026 summary\n", Legate.read(WORKSPACE / "reports_backup" / "summary.txt"))
