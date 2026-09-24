require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # A Symbol key that `inspect` can write bare (`name: 1`); any other
  # Symbol key is written quoted (`"foo bar": 1`).
  SIMPLE_SYMBOL_KEY = /\A[a-zA-Z_][a-zA-Z0-9_]*[?!=]?\z/

  # Builds the `Hash` class and its native methods. `[]`, `[]=` and
  # `==` are opcodes, not methods. Keys are looked up by Crystal's
  # `Hash(Value, Value)`: an Integer and an equal Float are the same
  # key, and an Array or Hash key matches only itself, both unlike
  # Ruby.
  def self.bootstrap_hash(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Hash")

    # Each key's and value's own `inspect`, so an object's override
    # applies, as `{"a" => 5, b: 6, "foo bar": 19}` (Ruby 4.0's
    # format). Every Symbol key uses the `key:` form, quoted when it
    # isn't a simple name. A cycle renders as `{...}`. `to_s` is the
    # same.
    define(cls, interp, "inspect") do |args, _blk, ncc|
      h = args.first.as_hash
      str = ncc.guard_rendering(h.object_id, "{...}") do
        pairs = h.keys.zip(h.values).map do |k, v|
          val_str = ncc.call_method(v, "inspect", [] of Adjutant::Value).as_string
          if k.symbol?
            name = k.as_sym.name
            label = name.matches?(SIMPLE_SYMBOL_KEY) ? name : ncc.call_method(Adjutant::Value.string(name), "inspect", [] of Adjutant::Value).as_string
            "#{label}: #{val_str}"
          else
            key_str = ncc.call_method(k, "inspect", [] of Adjutant::Value).as_string
            "#{key_str} => #{val_str}"
          end
        end
        "{" + pairs.join(", ") + "}"
      end
      Adjutant::Value.string(str)
    end

    define(cls, interp, "to_s") do |args, _blk, ncc|
      ncc.call_method(args.first, "inspect", [] of Adjutant::Value)
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
      h = args.first.as_hash
      Adjutant::Value.new(Adjutant::LabeledArray.new(h.keys, h.label), nil)
    end

    define(cls, interp, "values") do |args|
      h = args.first.as_hash
      Adjutant::Value.new(Adjutant::LabeledArray.new(h.values, h.label), nil)
    end

    # Three names for one check, as in Ruby.
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

    # Removes `key` and returns its value; if absent, the block's
    # result, or nil. The receiver's label is unchanged.
    define(cls, interp, "delete") do |args, blk, ncc|
      h = args.first.as_hash
      key = args[1]? || Adjutant::Value.nil_value
      if val = h.delete(key)
        val
      elsif blk
        ncc.invoke(blk, [key])
      else
        Adjutant::Value.nil_value
      end
    end

    # An Array of `[key, value]` pairs. Each pair's label joins its
    # key's and value's; the result's joins the pairs' and the
    # receiver's.
    define(cls, interp, "to_a") do |args|
      h = args.first.as_hash
      pairs = [] of Adjutant::Value
      h.each do |k, v|
        pair_label = Adjutant::RiskFlowLabel.join(k.label, v.label)
        pairs << Adjutant::Value.new(Adjutant::LabeledArray.new([k, v], pair_label), nil)
      end
      Adjutant::Value.new(Adjutant::LabeledArray.new(pairs, joined_label(pairs, h.label)), nil)
    end

    # A new Hash of the receiver and each argument, later keys winning,
    # or the block's result for a key in more than one:
    # `h1.merge(h2) { |key, old, new| }`. The label joins every hash's
    # and entry's.
    define(cls, interp, "merge") do |args, blk, ncc|
      recv_hash = args.first.as_hash
      others = args[1..]
      others.each do |other|
        unless other.hash?
          ncc.raise_error("R017", {"class_name" => builtin_type_name(other)}, "TypeError")
        end
      end

      merged = recv_hash.dup_entries
      label_seed = recv_hash.label
      others.each do |other|
        other_hash = other.as_hash
        label_seed = Adjutant::RiskFlowLabel.join(label_seed, other_hash.label)
        other_hash.each do |k, v|
          if blk && merged.has_key?(k)
            merged[k] = ncc.invoke(blk, [k, merged[k], v])
          else
            merged[k] = v
          end
        end
      end

      values_for_label = [] of Adjutant::Value
      merged.each { |k, v| values_for_label << k; values_for_label << v }
      Adjutant::Value.new(Adjutant::LabeledHash.new(merged, joined_label(values_for_label, label_seed)), nil)
    end

    cls
  end
end
