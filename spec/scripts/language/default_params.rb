require "assert"

# Probing a suspected gap found 2026-07-27 while auditing SCOPE.md: `Param`
# carries a `default` AST node, and `def greet(name = "world")` parses fine,
# but nothing in compiler.cr/vm.cr appears to ever read `.default` — arg
# binding looked like plain positional index-copy with no default-value
# fallback at all. If that's right, `greet` (no args) should leave `name`
# unbound (nil) rather than "world". Confirming with real assertions rather
# than static reading alone.

# --- TODO ... default params not implemented yet
# def greet(name = "world")
#   name
# end

# assert("default parameter value applies when the arg is omitted") do
#   greet == "world"
# end

# assert("default parameter value is overridden when the arg is given") do
#   greet("Ruby") == "Ruby"
# end

# def add(a, b = 10)
#   a + b
# end

# assert("a later default param applies with an earlier required param present") do
#   add(5) == 15
# end

# assert("multiple defaults each apply independently when both omitted") do
#   def pair(a = 1, b = 2)
#     [a, b]
#   end
#   pair == [1, 2]
# end
# ---
