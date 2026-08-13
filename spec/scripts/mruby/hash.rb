require "assert"

##
# Hash ISO Test
#
# NOTE: the upstream mruby Hash ISO suite leans almost entirely on a
# shared HashKey/HashEntries harness (custom `hash`/`eql?`/`==` on a
# user-defined Hash-key class, __send__, Array subclassing, default
# procs, freeze/rehash) that Adjutant doesn't support at all — nearly
# every upstream assertion is unreachable without that harness even
# for otherwise-trivial checks. Rewritten here as a self-contained
# file instead of a line-by-line port: real assertions, real ISO
# section numbers where they apply to something Adjutant actually
# supports, but no dependency on the unsupported harness. Only
# `{"k" => v}` (hash-rocket) literal syntax is used — `{k: v}`
# (symbol-shorthand) isn't parsed yet (see DEVELOPMENT.md).

assert('Hash', '15.2.13') do
  assert_equal(Class, Hash.class)
end

assert('Hash#[]', '15.2.13.4.2') do
  h = {"a" => 1, "b" => 2}
  assert_equal(1, h["a"])
  assert_equal(2, h["b"])
  assert_equal(nil, h["_not_found_"])
end

assert('Hash#[]=', '15.2.13.4.3') do
  h = {"a" => 1}
  h["b"] = 2
  assert_equal(2, h["b"])

  # duplicated key overwrites, size unchanged
  size = h.size
  h["a"] = 99
  assert_equal(size, h.size)
  assert_equal(99, h["a"])
end

assert('Hash#delete', '15.2.13.4.8') do
  h = {"a" => 1, "b" => 2}
  assert_equal(1, h.delete("a"))
  assert_equal(nil, h["a"])
  assert_equal(false, h.key?("a"))
  assert_equal(1, h.size)

  assert_equal(nil, h.delete("_not_found_"))
  assert_equal("default", h.delete("_not_found_") { "default" })
end

assert('Hash#each', '15.2.13.4.9') do
  h = {"a" => 1, "b" => 2, "c" => 3}
  sum = 0
  h.each { |k, v| sum += v }
  assert_equal(6, sum)
end

assert('Hash#empty?', '15.2.13.4.12') do
  assert_true({}.empty?)
  assert_false({"a" => 1}.empty?)
end

# --- BLOCKED: __send__ is deliberately excluded (U005), so this
# ISO-style "iterate over method-name aliases" pattern can't reach any
# of them via a single templated block. Each is asserted directly
# below instead.
# [["has_key?", "15.2.13.4.13"], ["include?", "15.2.13.4.15"], ["key?", "15.2.13.4.18"]].each do |meth, iso|
#   assert("Hash##{meth}", iso) do
#     h = {"a" => 1, "b" => 2}
#     assert_true(h.__send__(meth, "a"))
#     assert_false(h.__send__(meth, "z"))
#   end
# end
assert('Hash#has_key? / #include? / #key?') do
  h = {"a" => 1, "b" => 2}
  assert_true(h.has_key?("a"))
  assert_true(h.include?("a"))
  assert_true(h.key?("a"))
  assert_false(h.has_key?("z"))
  assert_false(h.include?("z"))
  assert_false(h.key?("z"))
end

# --- BLOCKED: same __send__ exclusion as above.
# [["keys", "15.2.13.4.19"], ["values", "15.2.13.4.28"]].each do |meth, iso|
#   assert("Hash##{meth}", iso) do
#     h = {"a" => 1, "b" => 2}
#     exp = meth == "keys" ? ["a", "b"] : [1, 2]
#     assert_equal(exp, h.__send__(meth))
#   end
# end
assert('Hash#keys / #values') do
  h = {"a" => 1, "b" => 2}
  assert_equal(["a", "b"], h.keys)
  assert_equal([1, 2], h.values)
end

# --- BLOCKED: same __send__ exclusion as above.
# [["length", "15.2.13.4.20"], ["size", "15.2.13.4.25"]].each do |meth, iso|
#   assert("Hash##{meth}", iso) do
#     h = {"a" => 1, "b" => 2}
#     assert_equal(2, h.__send__(meth))
#   end
# end
assert('Hash#length / #size') do
  h = {"a" => 1, "b" => 2}
  assert_equal(2, h.length)
  assert_equal(2, h.size)
  assert_equal(0, {}.length)
end

assert('Hash#merge', '15.2.13.4.22') do
  h1 = {"a" => 1, "b" => 2}
  h2 = {"b" => 20, "c" => 3}

  h3 = h1.merge(h2)
  assert_equal(1, h3["a"])
  assert_equal(20, h3["b"])
  assert_equal(3, h3["c"])
  # receiver untouched
  assert_equal(2, h1["b"])
  assert_equal(nil, h1["c"])

  # multiple arguments
  assert_equal({"a" => 1, "b" => 2, "c" => 3}, {"a" => 1}.merge({"b" => 2}, {"c" => 3}))

  # block resolves conflicts
  merged = h1.merge(h2) { |key, v1, v2| v1 + v2 }
  assert_equal(22, merged["b"])

  assert_raise(TypeError) { h1.merge("not a hash") }
end

assert('Hash#to_a') do
  h = {"a" => 1, "b" => 2}
  assert_equal([["a", 1], ["b", 2]], h.to_a)
  assert_equal([], {}.to_a)
end

# --- BLOCKED, real finding: Value#to_s (value.cr) has no case for
# LabeledArray or LabeledHash at all — both fall through to the
# generic `"#<" << @raw.class << ">"` fallback, so `{"a" => 1}.to_s`
# actually produces `"#<Adjutant::LabeledHash>"`, not a real
# Ruby-style `{"a" => 1}` rendering. Same root cause as the
# Array#to_s/#inspect gap already flagged in array.rb's own triage —
# but broader than realized there: no existing test anywhere in the
# suite (array_spec.cr included) ever checked #to_s's actual STRING
# CONTENT for either container type, only that it returns A string —
# so this has been silently wrong the whole time, not a partial gap.
# assert('Hash#to_s') do
#   assert_equal('{"a" => 1, "b" => 2}', {"a" => 1, "b" => 2}.to_s)
#   assert_equal('{}', {}.to_s)
# end

assert('Hash#==', '15.2.13.4.1') do
  assert_true({"a" => 1, "b" => 2} == {"a" => 1, "b" => 2})
  assert_false({"a" => 1} == {"a" => 1, "b" => 2})
  assert_false({"a" => 1} == {"a" => 2})
end

# # Not ISO specified

# --- BLOCKED: needs Hash.new(default)/default_proc, which don't
# exist — hash.cr has no singleton `new` override supporting either
# form.
# assert('Hash#default') do
#   h = Hash.new(-88)
#   assert_equal(-88, h["missing"])
# end

# --- BLOCKED: no #freeze/FrozenError.
# assert('Hash#freeze') do
#   h = {"a" => 1}.freeze
#   assert_raise(FrozenError) { h["b"] = 2 }
# end

# --- BLOCKED: #dup on a builtin-kind receiver raises NoMethodError
# (see SCOPE.md's Will Fix entry) rather than copying.
# assert('Hash#dup') do
#   h1 = {"a" => 1}
#   h2 = h1.dup
#   h2["b"] = 2
#   assert_false(h1.key?("b"))
# end

# --- BLOCKED: #shift, #clear, #replace, #rehash, #assoc/#rassoc,
# #select/#reject (and their mutating !-forms), #each_key/#each_value,
# #has_value?/#value?, #initialize (Hash.new with a default arg or
# block) — none of these exist yet.
