require "assert"

# Was a probe script (2026-07-27) confirming Class.new/Module.new
# silently succeeded despite the documented exclusion (now
# UNSUPPORTED.md's U002) claiming otherwise. As of 2026-07-27, that's fixed: RubyClass#uninstantiable?
# (set for Class/Module specifically at bootstrap, see
# Interpreter#bootstrap_core_hierarchy) makes VM#construct raise a
# clear error instead of falling through to the generic
# construct_object path. This file now verifies the fix.

assert("Class.new now raises a clear error instead of silently succeeding") do
  assert_raise do
    Class.new
  end
end

assert("Module.new now raises a clear error instead of silently succeeding") do
  assert_raise do
    Module.new
  end
end

assert("an ordinary class is completely unaffected by the guard") do
  class Ordinary
  end
  assert_nothing_raised do
    Ordinary.new
  end
end
