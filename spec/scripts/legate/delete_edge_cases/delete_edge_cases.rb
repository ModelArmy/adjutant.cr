require "assert"

# The delete grant's non-obvious behaviours — the ones a script author
# coming from `rm -rf` or Ruby's `FileUtils` would get wrong, and the
# ones the Crystal specs prove but nobody reads. Everything here is
# deliberate design, documented in `rm.cr`/`mv.cr`'s own top comments;
# none of it is incidental.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"
WORKSPACE = Legate::Path.new(__FILE__).parent / "workspace"

Legate.mkdir(WORKSPACE)

# --- The split that catches everyone: missing SOURCE, two answers ---
#
# A delete verb on a path that isn't there is not an error. `mv` from
# a path that isn't there raises `Legate::NotFound`. The difference is
# not an inconsistency: "make sure this isn't here" has already
# succeeded if it was never here, whereas "move this thing" with no
# thing to move is simply impossible.
#
# All three delete verbs agree; only the SPELLING of the non-result
# differs, following each verb's return type.

assert_equal(false, Legate.rm(WORKSPACE / "never-existed.txt"))
assert_equal(false, Legate.rmdir(WORKSPACE / "never-existed"))
assert_equal(0, Legate.rmdir!(WORKSPACE / "never-existed"))
assert_raise(Legate::NotFound) { Legate.mv(WORKSPACE / "never-existed.txt", WORKSPACE / "dest.txt") }

# --- The three verbs partition the target space exactly ---
#
# `rm` takes files, `rmdir` an empty directory, `rmdir!` a tree. Every
# refusal names the verb that would have worked, so a script that
# picked the wrong one is always one word from correct.

empty_dir = WORKSPACE / "empty"
Legate.mkdir(empty_dir)
assert_raise(Legate::Conflict) { Legate.rm(empty_dir) } # a directory, not a file
assert_equal(true, Legate.rmdir(empty_dir))

full_dir = WORKSPACE / "full"
Legate.mkdir(full_dir)
Legate.write(full_dir / "a.txt", "a\n")
assert_raise(Legate::Conflict) { Legate.rmdir(full_dir) } # not empty
assert_equal("a\n", Legate.read(full_dir / "a.txt")) # refused, and nothing was removed
assert_raise(Legate::Conflict) { Legate.rmdir!(full_dir / "a.txt") } # a file, not a directory

# --- What the returned count actually counts ---
#
# Every entry removed, the directory ITSELF included — not just the
# files inside it. `full/` + `full/a.txt` is 2.

assert_equal(2, Legate.rmdir!(full_dir))

# A deeper tree, spelled out so the arithmetic is checkable:
# tree/ + tree/top.txt + tree/sub/ + tree/sub/deep.txt = 4.
tree = WORKSPACE / "tree"
Legate.mkdir(tree / "sub")
Legate.write(tree / "top.txt", "top\n")
Legate.write(tree / "sub" / "deep.txt", "deep\n")
assert_equal(4, Legate.rmdir!(tree))

# --- mv REFUSES an occupied destination; mv! replaces it ---
#
# The same rule `write`/`write!` and `cp`/`cp!` follow, so the bang
# means one thing across the whole verb surface: "do the more
# destructive thing you would otherwise refuse."
#
# Note what a REFUSED move leaves behind: nothing has happened at
# all. The source is still at its original path, which is what makes
# `Legate::Conflict` recoverable in practice — a script can rescue it
# and pick another destination.

Legate.write(WORKSPACE / "new.txt", "new\n")
Legate.write(WORKSPACE / "old.txt", "old\n")
assert_raise(Legate::Conflict) { Legate.mv(WORKSPACE / "new.txt", WORKSPACE / "old.txt") }
assert_equal("old\n", Legate.read(WORKSPACE / "old.txt"))
assert_equal("new\n", Legate.read(WORKSPACE / "new.txt"))

Legate.mv!(WORKSPACE / "new.txt", WORKSPACE / "old.txt")
assert_equal("new\n", Legate.read(WORKSPACE / "old.txt"))
assert_nil(Legate.stat(WORKSPACE / "new.txt"))

# --- ...but mv REFUSES to replace one kind of thing with another ---
#
# A file over a directory, or a directory over a file, is never what
# a caller meant, so both are `Legate::Conflict` rather than a silent
# clobber.

occupied_dir = WORKSPACE / "occupied"
Legate.mkdir(occupied_dir)
Legate.write(WORKSPACE / "loose.txt", "loose\n")
assert_raise(Legate::Conflict) { Legate.mv(WORKSPACE / "loose.txt", occupied_dir) }
assert_equal("loose\n", Legate.read(WORKSPACE / "loose.txt")) # source survives a refused move

other_dir = WORKSPACE / "other"
Legate.mkdir(other_dir)
assert_raise(Legate::Conflict) { Legate.mv(other_dir, WORKSPACE / "loose.txt") }

# --- ...and refuses to replace a NON-EMPTY directory ---
#
# An empty destination directory is fine to move over; one with
# content in it would mean destroying unrelated data as a side effect
# of a move nobody asked to be destructive.

Legate.write(occupied_dir / "keep.txt", "keep\n")
assert_raise(Legate::Conflict) { Legate.mv(other_dir, occupied_dir) }
assert_equal("keep\n", Legate.read(occupied_dir / "keep.txt"))

# --- mv into a path whose parents don't exist yet ---
#
# Created automatically, the same as `write`/`cp`. §4.4 doesn't say
# so; `mv.cr` extends §4.3's stated behaviour by analogy, since a
# script author moving a file into a fresh output directory would be
# surprised to have to `mkdir` first when `cp` needs no such thing.

Legate.mv(WORKSPACE / "loose.txt", WORKSPACE / "deep" / "deeper" / "landed.txt")
assert_equal("loose\n", Legate.read(WORKSPACE / "deep" / "deeper" / "landed.txt"))

# --- rmdir! removes what a fresh mkdir would recreate ---
#
# Round-tripping, as a sanity check that neither verb leaves anything
# odd behind: after removing the tree, the same path is available to
# build on again.

assert_equal(3, Legate.rmdir!(WORKSPACE / "deep"))
Legate.mkdir(WORKSPACE / "deep")
assert(WORKSPACE.to_s + "/deep is a directory again") { Legate.stat(WORKSPACE / "deep").dir? }

# --- Nothing escaped the workspace ---

assert_equal("keep me\n", Legate.read(FIXTURES / "anchor.txt"))
