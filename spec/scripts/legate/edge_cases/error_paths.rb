require "assert"

# The recoverable Legate::Error subclasses (§2.4/§9.1) a script is
# actually meant to `rescue` around, demonstrated firing for real
# rather than only asserted from a Crystal-side spec — the whole
# point of a script in this directory over a spec file: this is what
# it actually looks like from the SCRIPT's own side of the boundary,
# in the same syntax a real embedder's script would use.
FIXTURES = Legate::Path.new(__FILE__).parent / "fixtures"

# --- Legate::TooLarge — Legate.lines' max_line: cap ---
#
# `long_line.txt`'s one line is 71 bytes (see fixtures/long_line.txt);
# `max_line: 20` makes even an ORDINARY line too long, raising mid-
# iteration rather than only for pathological gigabyte-long input —
# proving the cap is a real, reachable limit, not just a theoretical
# safety valve.
assert_raise(Legate::TooLarge) { Legate.lines(FIXTURES / "long_line.txt", max_line: 20).to_a }

# --- Legate::Malformed — scrub: false on invalid UTF-8 ---

assert_raise(Legate::Malformed) { Legate.read(FIXTURES / "invalid_utf8.txt", scrub: false) }

# --- scrub: true (the default) — invalid bytes replaced, not raised ---
#
# The SAME file as above, this time with the default `scrub: true` —
# `invalid_utf8.txt` is "hi" + one invalid byte + a newline; the
# invalid byte becomes U+FFFD rather than raising. Deliberately right
# next to the `scrub: false` case above: same file, same bad byte,
# opposite outcome purely from the kwarg — the clearest way to show
# these are two real, different behaviors, not one being a fallback
# for the other.
scrubbed = Legate.read(FIXTURES / "invalid_utf8.txt")
assert_equal("hi\uFFFD\n", scrubbed)

# --- Legate::TooMany — Legate.list's limit: cap ---
#
# `fixtures/many/` has 3 files; `limit: 2` makes even this small,
# ordinary directory listing exceed the cap.
assert_raise(Legate::TooMany) { Legate.list("#{FIXTURES}/many/*.txt", limit: 2) }

# --- Legate::TooMany — Legate.grep's limit: cap, same shape ---
#
# Each of the 3 files in fixtures/many/ contains one line ("x"), all
# three matching the pattern — `limit: 2` exceeds on the 3rd match,
# proving grep's OWN limit: (independent of list's) is real too, not
# just inherited/aliased from list's.
assert_raise(Legate::TooMany) { Legate.grep("x", "#{FIXTURES}/many/*.txt", limit: 2) }
