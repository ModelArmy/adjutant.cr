require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Decides which of the two Symbol-key spellings real Ruby's
  # Hash#inspect uses for the shorthand — a bare name (`name: value`)
  # if it matches, the name's own quoted-string form otherwise
  # (`"foo bar": value`) — NOT whether the shorthand applies at all;
  # confirmed against a real `irb` session that EVERY Symbol key uses
  # colon-shorthand, never hash-rocket. See bootstrap_hash's own
  # "SYMBOL-KEY SHORTHAND" comment for the full reasoning. Module-
  # level, not inline in the `inspect` block, so it's compiled once
  # rather than re-parsed as a Regex literal on every single
  # Hash#inspect call.
  SIMPLE_SYMBOL_KEY = /\A[a-zA-Z_][a-zA-Z0-9_]*[?!=]?\z/

  # Builds the `Hash` RubyClass and registers its native methods.
  #
  # `[]`/`[]=` are already real opcodes (Op::GetIndex/Op::SetIndex, see
  # exec_get_index/exec_set_index) — not registered here. `==` (same
  # key set, each value compared via values_equal?) is a real
  # values_equal? case, extended alongside Array's own bootstrap last
  # phase.
  #
  # Key lookup for `[]`/`[]=` (and this bootstrap's own methods) uses
  # Crystal's own Hash(Value, Value)#[], which hashes via Value's
  # auto-generated struct hash — NOT values_equal?. This was flagged
  # here as a cross-type numeric lookup gap (`{5 => "a"}[5.0]`
  # returning nil), but hash_spec.cr's own regression test found that
  # claim WRONG: Crystal's Int64/Float64#hash are already cross-type
  # consistent (5.hash == 5.0.hash when 5 == 5.0), so a numerically-
  # equal Float lookup already finds an Integer key correctly. The
  # narrower real gap: an Array or Hash used as a key still hashes by
  # REFERENCE, not content (same limitation noted in vm.cr's
  # values_equal?), and a user object with its own `hash`/`eql?`
  # doesn't participate in lookup at all (`hash`/`eql?` aren't real
  # methods for any type yet — see SCOPE.md).
  def self.bootstrap_hash(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Hash")

    # Real Ruby (as I understand it — worth a real `irb` check, not
    # independently confirmed here): `Hash#to_s` is a plain alias for
    # `Hash#inspect`, same as `Array`'s own aliasing (builtins/
    # array.cr). `to_s` here calls real dispatch on `inspect`
    # (`ncc.call_method`) rather than duplicating the same rendering
    # logic in two places.
    #
    # `inspect` itself: BOTH each key and each value rendered via
    # THEIR OWN real `inspect` (`ncc.call_method`, not a hand-rolled
    # per-type case) — a nested custom object's own `#inspect`
    # override is respected for free, same as Array's own elements.
    # Cycle-guarded via the SAME shared `NativeCallContext#
    # guard_rendering` Array uses (see that method's own comment) —
    # a Hash whose own value is itself (`h = {}; h["self"] = h`) now
    # renders as `{"self" => {...}}` rather than recursing until the
    # native stack overflows, and — since the guard is keyed on
    # object identity across ANY container type, not per-type state —
    # a cycle running THROUGH an Array (`a = []; h = {a: a}; a << h`)
    # is caught by the exact same mechanism, with no Hash-specific
    # tracking needed. `" => "` (with spaces) matches Ruby 4.0's
    # current default `Hash#inspect` format for the non-shorthand
    # case — worth a real `irb` check on whatever Ruby version matters
    # here, since this changed from the older, space-less `"a"=>1` at
    # some point and isn't something I independently verified beyond
    # your own earlier `irb` transcripts already showing Ruby 4.0.6.
    #
    # SYMBOL-KEY SHORTHAND: EVERY Symbol key uses `name: value`
    # notation, never hash-rocket — confirmed against a real `irb`
    # session (Ruby 4.0.6): `{ "a" => 5, b: 6, :c => 8, :"foo bar" =>
    # 19 }.inspect => {"a" => 5, b: 6, c: 8, "foo bar": 19}`. Two
    # things confirmed by that trace: the shorthand depends only on
    # the key's TYPE and NAME, not which literal syntax originally
    # built the Hash (`:c => 8` and `b: 6` both render as plain
    # `c: 8`/`b: 6`) — and an IRREGULAR name (`"foo bar"`, contains a
    # space) does NOT fall back to hash-rocket the way an earlier
    # draft of this assumed; it still uses colon-shorthand, just with
    # the name quoted like an ordinary String (`"foo bar": 19`, not
    # `:"foo bar" => 19`). `SIMPLE_SYMBOL_KEY` (module-level, above)
    # decides only WHICH of the two spellings to use — bare name if it
    # matches (a leading letter/underscore, then letters/digits/
    # underscores, optionally one trailing `?`/`!`/`=`), the name's
    # own real `inspect` (reusing String's quoting rules directly,
    # not hand-rolled here) otherwise. Non-Symbol keys are entirely
    # unaffected — they always use the uniform `key => value` form,
    # regardless of what they look like.
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

    # Real Ruby's Hash#delete removes the key and returns its value,
    # or nil if absent (or the block's result, if a block is given —
    # `h.delete(k) { |missing_key| ... }`). A MUTATION, not a new
    # container — same "monotonic, label untouched" convention
    # array.cr's #pop already establishes (no container-level label
    # recomputation needed, since removing an entry can only ever
    # narrow what's present, never introduce anything new).
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

    # Real Ruby's Hash#to_a converts each entry into a [key, value]
    # pair (a real 2-element Array), returning an Array of those
    # pairs. Two levels of NEW container here, both needing their own
    # label join per research/IFC_DESIGN.md's Container labeling
    # design (same principle array.cr's own select/reject/sort/
    # reverse/map already apply): each PAIR's label joins its own key
    # and value; the OUTER array's label seeds from the RECEIVER
    # hash's own container-level label, not just the pairs' labels,
    # so container-level-only taint (e.g. from a direct
    # declare_sensitivity call on the hash) survives the conversion.
    define(cls, interp, "to_a") do |args|
      h = args.first.as_hash
      pairs = [] of Adjutant::Value
      h.each do |k, v|
        pair_label = Adjutant::RiskFlowLabel.join(k.label, v.label)
        pairs << Adjutant::Value.new(Adjutant::LabeledArray.new([k, v], pair_label), nil)
      end
      Adjutant::Value.new(Adjutant::LabeledArray.new(pairs, joined_label(pairs, h.label)), nil)
    end

    # Real Ruby's Hash#merge accepts one or more Hash arguments,
    # returns a NEW hash (receiver untouched), later arguments'
    # duplicate keys overriding earlier ones — including the
    # receiver's own. An optional block resolves conflicts explicitly
    # instead: `h1.merge(h2) { |key, old_val, new_val| ... }`, called
    # once per key present in more than one of the hashes being
    # merged (in encounter order), its return value used instead of
    # the plain override.
    #
    # Label handling: a NEW container built from the entries of
    # MULTIPLE existing hashes — the join seeds from every involved
    # hash's own container-level label (receiver AND every argument),
    # not just the entries that end up in the result, same principle
    # as #to_a above and array.cr's select/reject/sort/reverse/map.
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
