require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Comparable` module. A class that includes it gets `==`,
  # `<`, `<=`, `>` and `>=` from its own `<=>`; the VM derives those
  # (`VM#comparable_object?`), since they are opcodes. `between?` and
  # `clamp` are native methods here. Integer, Float, String and Time
  # include it, as in Ruby.
  def self.bootstrap_comparable(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    mod = Adjutant::RubyClass.new("Comparable", nil, is_module: true)

    # Whether the receiver lies between `min` and `max`, inclusive. A
    # pair `<=>` can't order raises R044 (ArgumentError).
    define(mod, interp, "between?", arity: 2) do |args, _blk, ncc|
      recv = args.first
      Adjutant::Value.bool(ncc.order(recv, args[1]) >= 0 && ncc.order(recv, args[2]) <= 0)
    end

    # The receiver, or `min` or `max` if it lies outside them. `min`
    # above `max` raises R058 (ArgumentError), as in Ruby.
    define(mod, interp, "clamp", arity: 2) do |args, _blk, ncc|
      recv, min, max = args[0], args[1], args[2]
      if ncc.order(min, max) > 0
        ncc.raise_error("R058", {} of String => String, "ArgumentError")
      end
      if ncc.order(recv, min) < 0
        min
      elsif ncc.order(recv, max) > 0
        max
      else
        recv
      end
    end

    mod
  end
end
