require "assert"

# Class.new(name: ...) reaching a keyword-declaring `initialize` — the
# SCOPE.md Must Fix item promoted 2026-08-05, fixed 2026-08-08.
# Before this fix, ANY keyword argument to `.new` raised R012
# unconditionally (VM#dispatch_call's `.new` branch called
# reject_kwargs! before construct ever ran), regardless of whether
# the target class declared matching keyword params. Now kwargs
# thread through construct -> construct_object -> invoke ->
# call_script_proc -> bind_args, same per-Param machinery
# keyword_params.rb already exercises for ordinary methods.

class Config
  def initialize(retries:, timeout: 10)
    @retries = retries
    @timeout = timeout
  end

  def summary
    "retries=#{@retries} timeout=#{@timeout}"
  end
end

assert("a keyword-declaring initialize binds kwargs passed to .new") do
  Config.new(retries: 3, timeout: 5).summary == "retries=3 timeout=5"
end

assert("a kwarg's default applies when .new doesn't supply it") do
  Config.new(retries: 1).summary == "retries=1 timeout=10"
end

assert("a required kwarg never supplied to .new raises ArgumentError (R011)") do
  assert_raise(ArgumentError) { Config.new }
end

assert("an unknown keyword to .new raises ArgumentError (R012)") do
  assert_raise(ArgumentError) { Config.new(retries: 1, colour: "red") }
end

# A class with no `initialize` at all has nowhere for a keyword arg to
# bind — this must still fail loudly (R012), not silently drop it,
# same as it always has for a plain positional arg's sibling case.
class Bare
end

assert("a keyword arg to .new on a class with no initialize still raises") do
  assert_raise(ArgumentError) { Bare.new(anything: 1) }
end

assert("an ordinary no-kwarg .new call is completely unaffected") do
  assert_nothing_raised do
    Bare.new
  end
end

# Positional and keyword construction still combine, same as any
# other method call.
class Point
  def initialize(x, y, label: "point")
    @x = x
    @y = y
    @label = label
  end

  def describe
    "#{@label}(#{@x}, #{@y})"
  end
end

assert("positional and keyword args combine at a constructor too") do
  Point.new(1, 2, label: "origin").describe == "origin(1, 2)"
end
