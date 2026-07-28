require "assert"

# Probing a suspected gap found 2026-07-27, same root cause suspected as
# default_params.rb/splat_params.rb: `def foo(name:)`
# parses (Param#kwarg? is set — see parser_spec.cr), but arg binding looks
# like plain positional index-copy with no awareness of `Param#kwarg?`.
#
# Deliberately kept separate from the keyword-argument CALL-SITE case
# (now `parser_spec.cr`'s "does not yet parse keyword-argument syntax at
# a call site", moved out of spec/scripts/ 2026-07-27 since test_runner
# can't intercept a ParseError at all): THIS file only uses ordinary
# positional calls, which parse regardless of whether keyword-argument
# CALL syntax (`foo(name: "x")`) itself parses.

def greet(name:)
  name
end

assert("a kwarg param, called positionally, binds like an ordinary positional param today") do
  greet("Ruby") == "Ruby"
end

def greet_with_default(name: "world")
  name
end

assert("a kwarg param with a default, called with no args, does NOT get its default (see default_params.rb)") do
  assert_nil(greet_with_default)
end
