require "assert"

# Probing a suspected gap found 2026-07-27, same root cause suspected as
# default_params.rb/splat_params.rb: `def foo(name:)`
# parses (Param#kwarg? is set — see parser_spec.cr), but arg binding looks
# like plain positional index-copy with no awareness of `Param#kwarg?`.
#
# default_params.rb/splat_params.rb's half of this gap is fixed as of
# 2026-08-03 (Compiler#emit_default_prologue + VM#bind_args). THIS file's
# gap is not — kwarg binding (both the call-site `name: "x"` syntax, which
# doesn't parse yet, and required-kwarg enforcement) is a separate,
# unstarted piece (see SCOPE.md). emit_default_prologue explicitly skips
# any `Param#kwarg?` param even though it also carries a `default`, so
# `greet_with_default` below is expected to keep returning nil, not
# "world", until that piece lands.
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

assert("a kwarg param with a default, called with no args, does NOT get its default (kwargs are unimplemented — see this file's header)") do
  assert_nil(greet_with_default)
end
