require "assert"

# Argument-validation edge cases for LEGATE.md §4.7's ambient verbs —
# every R0xx (ERRORS.md) an ambient verb can raise, demonstrated the
# way a script author actually hits it. `Legate.scratch` has no
# arguments and so no edge cases of this shape; it isn't covered here.
#
# What this file deliberately does NOT cover, and why, is
# `ambient_basics.rb`'s own header comment — the fatal, unrescuable
# paths (`Legate.env` outside its allowlist, `Legate.fail` actually
# aborting) can't be demonstrated from inside a script without
# crashing this file's run. Everything below is a plain,
# script-rescuable `ArgumentError`/`TypeError`, raised BEFORE any of
# that would even be reached.

# --- Legate.random ---

assert_raise(ArgumentError) { Legate.random(0) }
assert_raise(ArgumentError) { Legate.random(-3) }
assert_raise(ArgumentError) { Legate.random(-0.5) }
assert_raise(TypeError) { Legate.random("nope") }
assert_raise(TypeError) { Legate.random([1, 2]) }

# --- Legate.log ---

assert_raise(ArgumentError) { Legate.log }
assert_raise(TypeError) { Legate.log(42) }
assert_raise(TypeError) { Legate.log("ok", "not a hash") }

# A field value with no plain representation (`Value#to_plain`,
# `value.cr`) — a lambda is the clearest example a script would
# actually write by accident (trying to log a callback, say).
assert_raise(TypeError) { Legate.log("ok", {bad: lambda { 1 }}) }

# A non-String, non-Symbol Hash KEY — distinct from the value case
# just above; `fields_of` (legate/verbs/log.cr) accepts either key
# spelling but nothing else.
assert_raise(TypeError) { Legate.log("ok", {1 => "nope"}) }

# But a deeply-nested, ordinary structure of loggable values is fine
# — this isn't an edge case, it's the contrast that proves the two
# rejections just above are about SHAPE, not depth.
assert_nothing_raised { Legate.log("ok", {a: {b: {c: [1, 2, {d: true}]}}}) }

# --- Legate.env ---

assert_raise(ArgumentError) { Legate.env }
assert_raise(TypeError) { Legate.env(42) }

# --- Legate.fail ---

assert_raise(ArgumentError) { Legate.fail }
assert_raise(TypeError) { Legate.fail(42) }
