require "assert"

# The `delete` grant's two verbs (LEGATE.md §4.4), used the way a real
# script would: as the tail end of a build-then-tidy-up cycle, not in
# isolation. `mv` and `rm` are the only verbs here that need the
# delete grant, but a realistic script reaches them via `mkdir`/
# `write` first — there is nothing to move or remove otherwise.
#
# Byte counts below were verified with `wc -c` before being written
# into an assertion, never computed by eye.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"
WORKSPACE = Legate::Path.new(__FILE__).parent / "workspace"

Legate.mkdir(WORKSPACE)

# --- Set the scene: a staging directory with real content in it ---

staging = WORKSPACE / "staging"
Legate.mkdir(staging)
assert_equal(17, Legate.write(staging / "report.txt", Legate.read(FIXTURES / "source.txt")))

# --- Legate.mv: rename within a directory ---
#
# The source is GONE afterwards, not merely copied — that's the whole
# difference between this verb and `cp`, and the reason §4.4 files it
# under `delete` rather than `write`.

moved = Legate.mv(staging / "report.txt", staging / "report-final.txt")
assert_nil(Legate.stat(staging / "report.txt"))
assert_equal("alpha\nbeta\ngamma\n", Legate.read(staging / "report-final.txt"))

# `mv` hands back a `Legate::Path` to the DESTINATION, ready to keep
# working with — no need to reconstruct the path the script just
# passed in.
assert_equal("report-final.txt", moved.basename)
assert_equal("alpha\nbeta\ngamma\n", Legate.read(moved))

# --- Legate.mv: relocate into a different directory ---
#
# Parent directories of the destination are created automatically,
# the same convenience `write`/`cp` already offer. `archive/2026/`
# does not exist before this call.

archived = Legate.mv(moved, WORKSPACE / "archive" / "2026" / "report.txt")
assert_equal("alpha\nbeta\ngamma\n", Legate.read(archived))
assert_nil(Legate.stat(staging / "report-final.txt"))

# --- Legate.mv: move a whole directory ---

Legate.write(staging / "scratch.txt", "temporary\n")
Legate.mv(staging, WORKSPACE / "staging-old")
assert_nil(Legate.stat(staging))
assert_equal("temporary\n", Legate.read(WORKSPACE / "staging-old" / "scratch.txt"))

# --- Legate.rm: a single file, returning whether one was removed ---
#
# Bool, not a count: a files-only verb can only ever remove one thing,
# and `if Legate.rm(p) > 0` is a clumsy spelling of a yes/no. The
# count lives on `Legate.rmdir!`, where "how many" is worth knowing.

assert_equal(true, Legate.rm(WORKSPACE / "staging-old" / "scratch.txt"))
assert_nil(Legate.stat(WORKSPACE / "staging-old" / "scratch.txt"))

# --- Legate.rmdir: an EMPTY directory ---
#
# `staging-old` is empty now that its only file is gone. `rm` would
# refuse it — the three delete verbs partition the target space, and
# each refusal names the one that would have worked.

assert_raise(Legate::Conflict) { Legate.rm(WORKSPACE / "staging-old") }
assert_equal(true, Legate.rmdir(WORKSPACE / "staging-old"))
assert_nil(Legate.stat(WORKSPACE / "staging-old"))

# --- Legate.rmdir!: a whole tree, counting what it removed ---
#
# The count is every entry removed, the directory itself included:
# `archive/` + `archive/2026/` + `archive/2026/report.txt` is 3.
# `rmdir` would refuse this one for being non-empty.

assert_raise(Legate::Conflict) { Legate.rmdir(WORKSPACE / "archive") }
assert_equal(3, Legate.rmdir!(WORKSPACE / "archive"))
assert_nil(Legate.stat(WORKSPACE / "archive"))

# --- Idempotence: removing what is already gone is not an error ---
#
# §2.3 — all three verbs agree, in the same spirit `mkdir` succeeds on
# a directory that already exists. "Make sure this isn't here" has
# already succeeded if it was never here. Only the SPELLING of the
# non-result differs, following each verb's return type.

assert_equal(0, Legate.rmdir!(WORKSPACE / "archive"))
assert_equal(false, Legate.rmdir(WORKSPACE / "archive"))
assert_equal(false, Legate.rm(WORKSPACE / "archive" / "gone.txt"))

# --- The fixtures were never touched ---
#
# The policy grants `delete` over `workspace/` alone, so nothing this
# script did could have reached the checked-in source content even by
# mistake.

assert_equal("alpha\nbeta\ngamma\n", Legate.read(FIXTURES / "source.txt"))
