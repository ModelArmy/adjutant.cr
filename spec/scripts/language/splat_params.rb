require "assert"

# Probing a suspected gap found 2026-07-27 alongside default_params.rb —
# same root cause suspected: `def sum(*args)` parses (see parser_spec.cr's
# "parses a def with a splat param"), but arg binding looked like plain
# positional index-copy with no awareness of `Param#splat?` at all.
# Confirmed the gap with real assertions; fixed 2026-08-03 via
# VM#bind_args/#collect_splat (see default_params.rb's header — same
# session, same underlying mechanism).

def sum(*args)
  args
end

assert("a splat param collects all extra positional args into an array") do
  sum(1, 2, 3) == [1, 2, 3]
end

assert("a splat param with zero args collects an empty array") do
  sum == []
end

def first_and_rest(first, *rest)
  [first, rest]
end

assert("a splat param after a required param collects only the remainder") do
  first_and_rest(1, 2, 3) == [1, [2, 3]]
end
