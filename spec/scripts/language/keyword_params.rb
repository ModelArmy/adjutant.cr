require "assert"

# Keyword arguments, end to end: call-site `name: value` parsing, and
# binding by name rather than position. Was two separate, incomplete
# pieces — this file used to be keyword_params_defsite.rb, pinning the
# (buggy) interim behavior where a kwarg param bound positionally and
# never got its default, because call-site `name: value` syntax didn't
# even parse yet (see parser_spec.cr's former "does not yet parse..."
# spec) and VM#bind_args had no Param#kwarg? branch at all. Both
# fixed 2026-08-04 (Parser#parse_call_arg, Compiler#compile_call +
# #emit_default_prologue, VM#bind_args) — see SCOPE.md history.

def greet(name:)
  name
end

assert("a required kwarg binds by name") do
  greet(name: "Ruby") == "Ruby"
end

assert("a required kwarg, never supplied, raises ArgumentError (R011)") do
  assert_raise(ArgumentError) { greet }
end

assert("a required kwarg, called positionally instead of by name, raises too") do
  # Real Ruby: positional args don't satisfy a keyword param. Before
  # this fix, `greet("Ruby")` silently bound "Ruby" into `name`
  # anyway — a plain positional index-copy that didn't know the
  # difference. Not anymore.
  assert_raise(ArgumentError) { greet("Ruby") }
end

def greet_with_default(name: "world")
  name
end

assert("a kwarg's default applies when the caller supplies nothing") do
  greet_with_default == "world"
end

assert("a kwarg's default is overridden when the caller supplies it") do
  greet_with_default(name: "Ruby") == "Ruby"
end

def describe(id, label: "item", qty: 1)
  "#{qty}x #{label} (#{id})"
end

assert("positional and keyword args combine, keywords in any order") do
  describe(42, qty: 3, label: "widget") == "3x widget (42)"
end

assert("a call with an unknown keyword raises ArgumentError (R012)") do
  assert_raise(ArgumentError) { describe(42, colour: "red") }
end

assert("a plain positional method rejects any keyword at all") do
  def add(a, b)
    a + b
  end
  assert_raise(ArgumentError) { add(1, 2, three: 3) }
end
