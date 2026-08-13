require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `String` RubyClass and registers its native methods.
  #
  # `+` and `==`/`<`/`<=`/`>`/`>=` are NOT registered here — they
  # already compile to dedicated VM opcodes (ValueOps.add, .equal?,
  # .compare in value_ops.cr all already have real String cases) the
  # same way Integer/Float's arithmetic does. `[]` (indexing) is also
  # already a real opcode (Op::GetIndex, see exec_get_index) — not
  # registered here either.
  #
  # `*` (string repetition, `"ab" * 3`) is NOT supported — ValueOps.op
  # has no String case, only Integer/Float. A real, separate gap from
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
      recv = args.first
      Adjutant::Value.int(recv.as_string.to_i64? || 0_i64, recv.label)
    end

    define(cls, interp, "to_f") do |args|
      recv = args.first
      Adjutant::Value.float(recv.as_string.to_f64? || 0.0, recv.label)
    end

    define(cls, interp, "to_sym") do |args|
      recv = args.first
      Adjutant::Value.symbol(interp.symbols.intern(recv.as_string), recv.label)
    end

    define(cls, interp, "length") do |args|
      Adjutant::Value.int(args.first.as_string.size.to_i64)
    end

    define(cls, interp, "size") do |args|
      Adjutant::Value.int(args.first.as_string.size.to_i64)
    end

    # upcase/downcase/strip/reverse/chars/capitalize all pass the
    # receiver's own label through to their result — a scalar-to-
    # scalar (or, for chars, scalar-to-container) transform of a
    # SINGLE labeled String, no combination of multiple sources
    # involved, so this is a direct carry-forward, not a join. Fixed
    # here alongside the new methods below (found while adding them —
    # upcase/downcase/strip previously dropped the receiver's label
    # entirely, the same category of gap already fixed for
    # Array#push/#map earlier this session).
    define(cls, interp, "upcase") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.upcase, recv.label)
    end

    define(cls, interp, "downcase") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.downcase, recv.label)
    end

    define(cls, interp, "strip") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.strip, recv.label)
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

    define(cls, interp, "reverse") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.reverse, recv.label)
    end

    define(cls, interp, "chars") do |args|
      recv = args.first
      # Same label-inheritance principle as #split above — an Array
      # of single-character substrings of a labeled receiver.
      Adjutant::Value.new(Adjutant::LabeledArray.new(recv.as_string.chars.map { |char| Adjutant::Value.string(char.to_s) }, recv.label), nil)
    end

    define(cls, interp, "start_with?") do |args|
      prefix = args[1]?.try(&.as_string?)
      Adjutant::Value.bool(prefix ? args.first.as_string.starts_with?(prefix) : false)
    end

    define(cls, interp, "end_with?") do |args|
      suffix = args[1]?.try(&.as_string?)
      Adjutant::Value.bool(suffix ? args.first.as_string.ends_with?(suffix) : false)
    end

    # Real Ruby's String#capitalize upcases the first character and
    # downcases every other one (`"heLLO wOrld".capitalize ==
    # "Hello world"`) — NOT just an upcase of the first letter with
    # the rest left alone, which is a common mistake this
    # implementation deliberately avoids. Crystal's own
    # String#capitalize does exactly this already, no manual
    # first-char-splitting needed.
    define(cls, interp, "capitalize") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.capitalize, recv.label)
    end

    cls
  end
end
