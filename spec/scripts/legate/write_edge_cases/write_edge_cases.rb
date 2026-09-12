require "assert"

# The write grant's non-obvious guarantees — none of it has a Ruby
# `File.write` analogue to fall back on, since real Ruby doesn't
# promise atomicity at all. `workspace/` doesn't exist on disk until
# this script's own `Legate.mkdir` call below creates it.
WORKSPACE = Legate::Path.new(__FILE__).parent / "workspace"
Legate.mkdir(WORKSPACE)

# --- write!'s atomicity: a failed write leaves ORIGINAL content untouched ---
#
# The 3rd element of the Array (42, not a String) makes this write
# fail partway through — write.cr's own atomicity means the ALREADY-
# EXISTING file at `target` is never touched at all by a write that
# ultimately fails; only the discarded temp file ever saw the bad
# data.
#
# `write!`, not `write`, and the bang is the whole point of the test:
# the plain verb now refuses an existing destination outright, so it
# could never reach the atomicity path this block exercises. Only the
# replacing verb can fail PARTWAY THROUGH replacing something, which
# is precisely the case where atomicity has to hold — the bang is the
# one that needs this guarantee, and now the one that is checked for
# it.
target = WORKSPACE / "atomic.txt"
Legate.write(target, "original content")
assert_raise(TypeError) { Legate.write!(target, ["a", 42, "c"]) }
assert_equal("original content", Legate.read(target))

# The plain verb's refusal, on the same already-occupied path — the
# other half of the split, checked here rather than left to the
# Crystal-level spec, since this file is where a script author reads
# what the two verbs do differently.
assert_raise(Legate::Conflict) { Legate.write(target, "clobbered") }
assert_equal("original content", Legate.read(target))

# --- no .tmp file is ever left behind, success or failure ---
#
# `"#{WORKSPACE}/*"` would NOT actually prove this — POSIX glob `*`
# excludes dotfiles by default (same convention Ruby's own `Dir.glob`
# follows, which `Legate.list` inherits directly), so it would never
# even SEE a leaked `.legate-write-*.tmp` file, making the check
# trivially pass regardless of whether cleanup actually worked. The
# temp-file prefix is write.cr's own, known naming convention —
# matching it directly is what actually proves the leak didn't happen.
assert_equal(0, Legate.list("#{WORKSPACE}/.legate-write-*").length)

# --- append's DIFFERENTLY-DOCUMENTED guarantee: NO atomicity at all ---
#
# Contrast this directly with `write`'s test just above: here "a" and
# "b" (the first two elements) genuinely reach disk BEFORE the 3rd
# element's TypeError — append.cr makes no temp-file/rename promise
# (LEGATE.md's atomicity sentence names `write` alone), so there's no
# rollback. This is the DOCUMENTED, deliberate behavior, not a bug —
# see append.cr's own top comment for why the two verbs differ here.
log = WORKSPACE / "log.txt"
Legate.write(log, "start-")
assert_raise(TypeError) { Legate.append(log, ["a", "b", 42, "d"]) }
assert_equal("start-ab", Legate.read(log))

# --- Legate::Conflict: mkdir where a FILE already exists ---

file_path = WORKSPACE / "just_a_file.txt"
Legate.write(file_path, "hi")
assert_raise(Legate::Conflict) { Legate.mkdir(file_path) }

# --- Legate::Conflict: write where a DIRECTORY already exists ---

dir_path = WORKSPACE / "just_a_dir"
Legate.mkdir(dir_path)
assert_raise(Legate::Conflict) { Legate.write(dir_path, "hi") }

# --- Legate::NotFound: cp from a source that doesn't exist ---

assert_raise(Legate::NotFound) { Legate.cp(WORKSPACE / "does-not-exist.txt", WORKSPACE / "dest.txt") }

# --- Legate::Conflict: cp a directory without recursive: true ---
#
# `dir_path` is a real, existing directory (created above) — copying
# it requires an explicit `recursive: true`, the same "opt in
# deliberately, not by accident" reasoning cp.cr's own comment gives.
assert_raise(Legate::Conflict) { Legate.cp(dir_path, WORKSPACE / "dir_copy") }
