require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Hash` RubyClass and registers its native methods.
  #
  # `[]`/`[]=` are already real opcodes (Op::GetIndex/Op::SetIndex, see
  # exec_get_index/exec_set_index) — not registered here. `==` (same
  # key set, each value compared via values_equal?) is a real
  # values_equal? case, extended alongside Array's own bootstrap last
  # phase.
  #
  # IMPORTANT, pre-existing gap (not introduced by this file): key
  # lookup for `[]`/`[]=` uses Crystal's own Hash(Value, Value)#[],
  # which hashes via Value's auto-generated struct hash — NOT
  # values_equal?. This means `{5 => "a"}[5.0]` returns nil, not "a",
  # even though `5 == 5.0` is true in script (values_equal? DOES
  # consider them equal) — Int64 and Float64 hash differently even for
  # numerically-equal values. Symbol/String/Integer/Float/Bool/Nil keys
  # are internally consistent (a Symbol key always hashes/compares
  # against itself correctly; the gap is only CROSS-type numeric
  # lookups). An Array or Hash used as a key has the same narrow issue
  # noted in vm.cr's values_equal? — it hashes by reference, not
  # content. Native to this Hash bootstrap's own methods too (each,
  # keys, values, include?/key? all walk the same underlying
  # Hash(Value, Value)), not something `each`/`keys` could route
  # around on their own.
  def self.bootstrap_hash(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Hash")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.to_s)
    end

    define(cls, interp, "length") do |args|
      Adjutant::Value.int(args.first.as_hash.size.to_i64)
    end

    define(cls, interp, "size") do |args|
      Adjutant::Value.int(args.first.as_hash.size.to_i64)
    end

    define(cls, interp, "empty?") do |args|
      Adjutant::Value.bool(args.first.as_hash.empty?)
    end

    define(cls, interp, "keys") do |args|
      Adjutant::Value.new(args.first.as_hash.keys, nil)
    end

    define(cls, interp, "values") do |args|
      Adjutant::Value.new(args.first.as_hash.values, nil)
    end

    # `key?` is the real Ruby name; `include?` and `has_key?` are
    # common aliases for the same check — all three registered as
    # separate entries in native_methods (not literal Ruby aliasing,
    # which Adjutant doesn't support as a language feature) so a
    # script can use whichever it's used to.
    {"key?", "include?", "has_key?"}.each do |name|
      define(cls, interp, name) do |args|
        key = args[1]? || Adjutant::Value.nil_value
        Adjutant::Value.bool(args.first.as_hash.has_key?(key))
      end
    end

    define(cls, interp, "each") do |args, blk, ncc|
      recv = args.first
      if blk
        recv.as_hash.each { |k, v| ncc.invoke(blk, [k, v]) }
      end
      recv
    end

    cls
  end
end
