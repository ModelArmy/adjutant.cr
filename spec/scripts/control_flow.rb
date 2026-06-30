#
# TODO
# - [ ] Support `if...` as expressions, not statements. See commented-out section below
#
require "assert"

assert("ternary") {
  (1 > 0 ? :yes : :no) == :yes
}

assert("while loop counts correctly") {
  x = 0
  while x < 5
    x += 1
  end
  x == 5
}

assert("modifier if") {
  x = 1
  x = 2 if true
  x == 2
}

assert("modifier unless") {
  x = 1
  x = 2 unless false
  x == 2
}

assert("modifier while") {
  x = 0
  x += 1 while x < 3
  x == 3
}

# ------ if... statements

assert("elsif chain (stmt)") {
  x = 2
  result = nil
  if x == 1
    result = :one
  elsif x == 2
    result = :two
  else
    result = :other
  end
  result == :two
}

assert("if-then (stmt)") {
  result = nil
  if true
    result = 1
  end
  result == 1
}

assert("if-else (stmt)") {
  result = nil
  if false
    result = 1
  else
    result = 2
  end
  result == 2
}

assert("unless (stmt)") {
  result = nil
  unless false
    result = :yes
  end
  result == :yes
}

# ------ if... expressions NOT SUPPORTED

# assert("if-then") {
#   if true
#     1
#   end == 1
# }

# assert("if-else") {
#   result = if false
#     1
#   else
#     2
#   end
#   result == 2
# }

# assert("elsif chain (expr)") {
#   x = 2
#   result = if x == 1
#     :one
#   elsif x == 2
#     :two
#   else
#     :other
#   end
#   result == :two
# }

# assert("unless") {
#   result = unless false
#     :yes
#   end
#   result == :yes
# }
