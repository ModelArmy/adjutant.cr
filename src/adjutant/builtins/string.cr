require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `String` RubyClass and registers its native methods.
  #
  # `+` and `==`/`<`/`<=`/`>`/`>=` are NOT registered here — they
  # already compile to dedicated VM opcodes (arith_add, values_equal?,
  # compare_op in vm.cr all already have real String cases) the same
  # way Integer/Float's arithmetic does. `[]` (indexing) is also
  # already a real opcode (Op::GetIndex, see exec_get_index) — not
  # registered here either.
  #
  # `*` (string repetition, `"ab" * 3`) is NOT supported — arith_op has
  # no String case, only Integer/Float. A real, separate gap from
  # anything this class controls; noted, not fixed here (this class
  # only wires up NATIVE METHODS, not opcodes).
  #
  # `length`/`size` were previously served by exec_builtin's generic,
  # receiver-agnostic fallback case (see vm.cr) — registering them
  # here as real native methods makes THIS class authoritative for
  # String specifically going forward, via find_native_method, which
  # dispatch checks before ever reaching that fallback. The fallback's
  # own `string?` branch inside `length`/`size` is now dead code for
  # strings, but stays live for Array/Hash until those land too.
  def self.bootstrap_string(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("String")

    define(cls, interp, "to_s") do |args|
      args.first
    end

    define(cls, interp, "to_i") do |args|
      Adjutant::Value.int(args.first.as_string.to_i64? || 0_i64)
    end

    define(cls, interp, "to_f") do |args|
      Adjutant::Value.float(args.first.as_string.to_f64? || 0.0)
    end

    define(cls, interp, "to_sym") do |args|
      Adjutant::Value.symbol(interp.symbols.intern(args.first.as_string))
    end

    define(cls, interp, "length") do |args|
      Adjutant::Value.int(args.first.as_string.size.to_i64)
    end

    define(cls, interp, "size") do |args|
      Adjutant::Value.int(args.first.as_string.size.to_i64)
    end

    define(cls, interp, "upcase") do |args|
      Adjutant::Value.string(args.first.as_string.upcase)
    end

    define(cls, interp, "downcase") do |args|
      Adjutant::Value.string(args.first.as_string.downcase)
    end

    define(cls, interp, "strip") do |args|
      Adjutant::Value.string(args.first.as_string.strip)
    end

    define(cls, interp, "empty?") do |args|
      Adjutant::Value.bool(args.first.as_string.empty?)
    end

    define(cls, interp, "include?") do |args|
      needle = args[1]?.try(&.as_string?)
      Adjutant::Value.bool(needle ? args.first.as_string.includes?(needle) : false)
    end

    define(cls, interp, "split") do |args|
      recv = args.first
      s = recv.as_string
      sep = args[1]?.try(&.as_string?)
      parts = sep ? s.split(sep) : s.split
      # Parts are substrings of a labeled receiver — the array as a
      # whole inherits the receiver's label, same principle as any other
      # construction from a labeled source (see MakeArray/MakeHash).
      Adjutant::Value.new(Adjutant::LabeledArray.new(parts.map { |part| Adjutant::Value.string(part) }, recv.label), nil)
    end

    cls
  end
end
