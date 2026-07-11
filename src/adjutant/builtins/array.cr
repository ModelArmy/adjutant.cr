require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Array` RubyClass and registers its native methods.
  #
  # `+` and `<<` are NOT registered here — `+` (concatenation, returns
  # a new array) is now a real arith_add case, and `<<` (in-place
  # append, returns self) is a real exec_shl case — see vm.cr, both
  # extended alongside this class since real Ruby overloads those
  # operators across Integer/String/Array and they're unreachable via
  # find_native_method regardless (same reasoning as Integer/Float/
  # String's own arithmetic). `[]`/`[]=` are also already real opcodes
  # (Op::GetIndex/Op::SetIndex, see exec_get_index/exec_set_index) —
  # not registered here either. `==` (deep, element-wise) is a real
  # values_equal? case, also extended alongside this class.
  #
  # `length`/`size` follow String's precedent: previously served by
  # exec_builtin's generic fallback, now authoritative here via
  # find_native_method (checked first in dispatch).
  #
  # `each`/`map` are the first native methods that actually invoke a
  # script-provided block, via NativeCallContext#invoke — confirmed
  # working end-to-end by existing block-from-native machinery (see
  # DEVELOPMENT.md's Object model section) before this file was
  # written, not assumed.
  def self.bootstrap_array(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Array")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.to_s)
    end

    define(cls, interp, "length") do |args|
      Adjutant::Value.int(args.first.as_array.size.to_i64)
    end

    define(cls, interp, "size") do |args|
      Adjutant::Value.int(args.first.as_array.size.to_i64)
    end

    define(cls, interp, "empty?") do |args|
      Adjutant::Value.bool(args.first.as_array.empty?)
    end

    define(cls, interp, "push") do |args|
      # Real Ruby's Array#push accepts multiple arguments and appends
      # all of them, returning self — `args[1..]` is every argument
      # after the receiver, not just one.
      arr = args.first.as_array
      args[1..].each { |v| arr.push(v) }
      args.first
    end

    define(cls, interp, "pop") do |args|
      arr = args.first.as_array
      arr.empty? ? Adjutant::Value.nil_value : arr.pop
    end

    define(cls, interp, "include?") do |args, _blk, ncc|
      needle = args[1]?
      found = needle ? args.first.as_array.any? { |elem| ncc.values_equal?(elem, needle) } : false
      Adjutant::Value.bool(found)
    end

    define(cls, interp, "join") do |args|
      sep = args[1]?.try(&.as_string?) || ""
      Adjutant::Value.string(args.first.as_array.map(&.to_s).join(sep))
    end

    define(cls, interp, "each") do |args, blk, ncc|
      recv = args.first
      if blk
        recv.as_array.each { |elem| ncc.invoke(blk, [elem]) }
      end
      recv
    end

    define(cls, interp, "map") do |args, blk, ncc|
      recv = args.first
      if blk
        Adjutant::Value.new(recv.as_array.map { |elem| ncc.invoke(blk, [elem]) }, nil)
      else
        Adjutant::Value.new([] of Adjutant::Value, nil)
      end
    end

    cls
  end
end
