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

# ------ if... expressions

assert("if-then (expr)") {
  (if true
    1
  end) == 1
}

assert("if-then with no match yields nil (expr)") {
  result = if false
    1
  end
  result == nil
}

assert("if-else (expr)") {
  result = if false
    1
  else
    2
  end
  result == 2
}

assert("elsif chain (expr)") {
  x = 2
  result = if x == 1
    :one
  elsif x == 2
    :two
  else
    :other
  end
  result == :two
}

assert("unless (expr)") {
  result = unless false
    :yes
  end
  result == :yes
}

assert("if as call argument") {
  (if true
    2
  else
    3
  end) == 2
}

# ------ case... expressions

assert("case (expr)") {
  x = 2
  result = case x
  when 1
    :one
  when 2
    :two
  else
    :other
  end
  result == :two
}

assert("case with no match yields nil (expr)") {
  result = case 99
  when 1
    :one
  end
  result == nil
}

# ------ begin/rescue expressions

assert("begin-rescue yields body value on success (expr)") {
  result = begin
    1 + 1
  rescue e
    :failed
  end
  result == 2
}

assert("begin-rescue yields rescue value on error (expr)") {
  result = begin
    1 / 0
  rescue e
    :failed
  end
  result == :failed
}

assert("begin-rescue binds the error message to the rescue var") {
  result = begin
    1 / 0
  rescue e
    e
  end
  result == "divided by 0"
}

assert("begin-rescue catches an error raised several calls deep") {
  def blow_up
    1 / 0
  end

  result = begin
    blow_up()
  rescue e
    :caught
  end
  result == :caught
}

assert("begin-rescue catches an explicit raise") {
  result = begin
    raise "boom"
  rescue e
    e
  end
  result == "boom"
}

assert("code after a caught error in the same begin body does not run") {
  ran_after = false
  begin
    1 / 0
    ran_after = true
  rescue e
    nil
  end
  ran_after == false
}
