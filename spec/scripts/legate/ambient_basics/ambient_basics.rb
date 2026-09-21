require "assert"

# LEGATE.md §4.7's six ambient verbs, used the way a real script
# actually would — a small agent-shaped sequence (stage work, narrate
# it, bail cleanly if something's wrong), not each verb poked in
# isolation. See `ambient_edge_cases.rb` for the error-path coverage
# this file mostly avoids.
#
# Two things this suite deliberately does NOT exercise, both for the
# same reason `basics/reading.rb` already established for
# `Legate::Denied`: a fatal signal is a plain Crystal `Exception`, not
# a `RuntimeError` (`fatal_signal.cr`'s own comment — "deliberately
# unrescuable by any script rescue"), so neither `assert_raise` nor an
# ordinary script `rescue` can catch one; attempting it here would
# crash this whole file's run rather than produce a clean assertion
# failure.
#   - `Legate.env` returning a REAL value for a SET variable. This
#     suite can prove "allowlisted but unset returns nil" (below)
#     without any external setup, but proving "allowlisted and set
#     returns the value" needs the process's own environment
#     configured BEFORE the interpreter starts, which this test-script
#     layer has no portable, CI-safe way to arrange. Proved at the
#     Crystal level instead (`env_spec.cr`, which sets `ENV[...]`
#     directly before constructing the Interpreter).
#   - `Legate.env` denying a name outside the allowlist, and
#     `Legate.fail` actually aborting. Both raise `Legate::Denied`/
#     `Legate::Aborted` — fatal, unrescuable, same reasoning as above.
#     Proved at the Crystal level instead (`env_spec.cr`, `fail_spec.cr`).

# --- Legate.scratch: pre-granted working space, no write: grant needed ---

work = Legate.scratch
assert("scratch returns a Path to a real, already-existing directory") { Legate.stat(work).dir? }

# The SAME directory for every call within this one run (LEGATE.md
# §4.7's own "granted by default" is a per-run allowance, not a
# fresh directory each time).
assert_equal(work.to_s, Legate.scratch.to_s)

# --- Composition: write/read/rm INSIDE scratch, no write/read/delete grant at all ---
#
# This is the actual point of `Legate.scratch` existing — proving
# `Legate::Broker#ambient_roots` folds the scratch path into
# `authorize_write`/`authorize_read`/`authorize_delete` from here on,
# even though this suite's own `_policy.yaml` grants none of the
# three.
note_path = work / "notes.txt"
Legate.write(note_path, "staged by ambient_basics\n")
assert_equal("staged by ambient_basics\n", Legate.read(note_path))
assert_equal(true, Legate.rm(note_path))

# --- Legate.now: the same Time class an unrestricted Time.now returns ---

stamp = Legate.now
assert("Legate.now returns a Time") { stamp.is_a?(Time) }
assert("the year is a real one, not a placeholder/epoch value") { stamp.year >= 2024 }

# --- Legate.random: no n (a Float), an Integer n, a Float n ---

r0 = Legate.random
assert("no-arg random is a Float") { r0.is_a?(Float) }
assert("...in [0.0, 1.0)") { r0 >= 0.0 && r0 < 1.0 }

r1 = Legate.random(10)
assert("Legate.random(10) is an Integer") { r1.is_a?(Integer) }
assert("...in [0, 10)") { r1 >= 0 && r1 < 10 }

r2 = Legate.random(2.5)
assert("Legate.random(2.5) is a Float") { r2.is_a?(Float) }
assert("...in [0.0, 2.5)") { r2 >= 0.0 && r2 < 2.5 }

# --- Legate.log: message alone, then with structured fields ---
#
# Both key spellings (`{tries: 3}` and `{"tries" => 3}`), and a
# nested Array/Hash of loggable values — exactly the shape
# `Value#to_plain` (`value.cr`) has to walk recursively. Nothing here
# inspects what actually reached the embedder's `::Log` (this suite's
# Interpreter never configures one — LEGATE.md §4.7's own "a no-op
# until the embedder configures a backend"); it only proves the CALL
# itself succeeds for every shape a script might reasonably write.
# `Log::MemoryBackend`-based inspection of the actual delivered entry
# is `log_spec.cr`'s job, at the Crystal level, where a capturing
# backend can be wired in directly.
assert_nothing_raised { Legate.log("staged scratch work") }
assert_nothing_raised { Legate.log("staged scratch work", {tries: 1, ok: true}) }
assert_nothing_raised { Legate.log("staged scratch work", {"tries" => 1, "ok" => true}) }
assert_nothing_raised do
  Legate.log("nested fields", {tags: ["ambient", "smoke-test"], meta: {run: r1, ok: true}})
end
assert_equal(nil, Legate.log("returns nil"))

# --- Legate.env: allowlisted but unset returns nil ---

assert_nil(Legate.env("ADJUTANT_AMBIENT_TEST_UNSET_VAR"))

# --- Legate.fail's argument validation is rescuable; the abort itself is not ---
#
# `message` is required — this is an ordinary ArgumentError (R040),
# raised BEFORE any abort would happen, so it's safe to demonstrate
# here unlike the abort itself (see this file's own header comment).
assert_raise(ArgumentError) { Legate.fail }
