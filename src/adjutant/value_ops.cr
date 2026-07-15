module Adjutant
  # Every operator's actual type-dispatch logic (`+`, `-`, `*`, `/`,
  # `%`, `&`, `|`, `^`, `<<`, `>>`, `<`, `<=`, `>`, `>=`, `==`), in one
  # place. Previously scattered across VM as arith_add/arith_op/
  # arith_div/arith_mod/int_op/exec_shl/compare_op/values_equal? —
  # each VM opcode handler called straight into its own method, and at
  # least one spec helper (FakeContext, in spec_helper.cr) had its own
  # third copy of compare_op's int/float/string logic, since there was
  # no VM-independent place to call into. This module is that place.
  #
  # Pure type dispatch — no VM/Interpreter/RubyClass-instance state.
  # `RubyObject` operands are NOT handled here (a script class
  # overriding `+`/`<=>`/etc. isn't supported yet — see the
  # 2026-07-14-session design discussion on operator overloading,
  # Option B piece 2); a RubyObject operand falls through to each
  # method's own "no valid conversion" error/false case exactly like
  # any other unrecognized type pairing would, with no special
  # handling either way.
  #
  # The arithmetic family (`add`/`op`/`div`/`mod`/`int_op`) can fail
  # (type errors, divide-by-zero) and takes an explicit `on_error`
  # proc rather than raising a `RuntimeError` directly — `Value` and
  # this module have no reference to a VM, so they can't build the
  # rich, script-catchable error object VM#runtime_error constructs
  # (a real RubyObject of the RuntimeError class, not just a message
  # string — see VM#make_error_object). The caller supplies how to
  # raise; VM passes a proc that calls its own runtime_error, so the
  # only place that knows how to build a proper script-visible error
  # stays VM#runtime_error, and the only place that knows operator
  # semantics is here. `compare`/`equal?` never fail (an unrecognized
  # pairing is `false`, matching real Ruby's `<=>` returning nil /
  # `==` returning false rather than raising), so they take no
  # `on_error` — nothing to thread through for them.
  module ValueOps
    alias OnError = String -> NoReturn

    # ameba:disable Metrics/CyclomaticComplexity
    def self.add(a : Value, b : Value, on_error : OnError) : Value
      case
      when a.int? && b.int?       then Value.int(a.as_int + b.as_int)
      when a.float? && b.float?   then Value.float(a.as_float + b.as_float)
      when a.int? && b.float?     then Value.float(a.as_int.to_f64 + b.as_float)
      when a.float? && b.int?     then Value.float(a.as_float + b.as_int.to_f64)
      when a.string? && b.string? then Value.string(a.as_string + b.as_string)
      when a.array? && b.array?
        # Real Ruby's Array#+ returns a NEW array (the two operands are
        # untouched) — a fresh LabeledArray wrapping a fresh Crystal
        # array, same construction Op::MakeArray itself uses, not a
        # mutation of either a's or b's underlying array. The result's
        # label is set by VM#exec_binary's outer with_label call (join
        # of a's and b's labels), same as any other binary op — this
        # module doesn't touch labels itself.
        Value.new(LabeledArray.new(a.as_array.dup_items + b.as_array.dup_items), nil)
      else
        on_error.call("cannot add #{a} and #{b}")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def self.op(a : Value, b : Value, op : Symbol, on_error : OnError) : Value
      case
      when a.int? && b.int?
        n = case op
            when :- then a.as_int - b.as_int
            when :* then a.as_int * b.as_int
            else         0_i64
            end
        Value.int(n)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        n = case op
            when :- then fa - fb
            when :* then fa * fb
            else         0.0
            end
        Value.float(n)
      else
        on_error.call("type error in arithmetic")
      end
    end

    def self.div(a : Value, b : Value, on_error : OnError) : Value
      case
      when a.int? && b.int?
        on_error.call("divided by 0") if b.as_int == 0
        Value.int(a.as_int // b.as_int)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        on_error.call("divided by 0") if fb == 0.0
        Value.float(fa / fb)
      else
        on_error.call("type error in division")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def self.mod(a : Value, b : Value, on_error : OnError) : Value
      on_error.call("divided by 0") if (b.int? && b.as_int == 0) || (b.float? && b.as_float == 0.0)
      case
      when a.int? && b.int? then Value.int(a.as_int % b.as_int)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        Value.float(fa % fb)
      else
        on_error.call("type error in modulo")
      end
    end

    def self.int_op(a : Value, b : Value, op : Symbol, on_error : OnError) : Value
      on_error.call("bitwise op requires Integer") unless a.int? && b.int?
      n = case op
          when :&  then a.as_int & b.as_int
          when :|  then a.as_int | b.as_int
          when :^  then a.as_int ^ b.as_int
          when :<< then a.as_int << b.as_int
          when :>> then a.as_int >> b.as_int
          else          0_i64
          end
      Value.int(n)
    end

    # `<<` is overloaded in real Ruby between Integer's bit-shift and
    # Array's append-and-return-self — genuinely different operations
    # sharing one operator. Split out from int_op (which stays
    # Integer-only, still backing `&`/`|`/`^`/`>>`) rather than adding
    # an array branch inside it, so those other bitwise ops don't
    # silently gain array behavior they were never meant to have.
    def self.shl(a : Value, b : Value, on_error : OnError) : Value
      if a.array?
        # Real Ruby: mutates a in place AND returns a (so `arr << 1 <<
        # 2` chains) — push onto the same underlying LabeledArray, not
        # a new one. Returning `a` here means VM#exec_binary's outer
        # `.with_label(join(a.label, b.label))` call mutates this same
        # LabeledArray's own label field (see Value#with_label's
        # container case) — the container accumulates b's taint for
        # free, same as Op::SetIndex.
        a.as_array.push(b)
        a
      else
        int_op(a, b, :<<, on_error)
      end
    end

    # Never fails — an unrecognized type pairing is simply `false`,
    # matching real Ruby's `<=>` returning nil for incomparable types
    # rather than raising. No `on_error` to thread through.
    # ameba:disable Metrics/CyclomaticComplexity
    def self.compare(a : Value, b : Value, op : Symbol) : Bool
      case
      when a.int? && b.int?
        case op
        when :<  then a.as_int < b.as_int
        when :<= then a.as_int <= b.as_int
        when :>  then a.as_int > b.as_int
        when :>= then a.as_int >= b.as_int
        else          false
        end
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        case op
        when :<  then fa < fb
        when :<= then fa <= fb
        when :>  then fa > fb
        when :>= then fa >= fb
        else          false
        end
      when a.string? && b.string?
        case op
        when :<  then a.as_string < b.as_string
        when :<= then a.as_string <= b.as_string
        when :>  then a.as_string > b.as_string
        when :>= then a.as_string >= b.as_string
        else          false
        end
      else
        false
      end
    end

    # Never fails — an unrecognized/mismatched type pairing is simply
    # `false`, matching real Ruby's `==` (never raises by default). No
    # `on_error` to thread through.
    # ameba:disable Metrics/CyclomaticComplexity
    def self.equal?(a : Value, b : Value) : Bool
      case
      when a.null? && b.null?     then true
      when a.bool? && b.bool?     then a.as_bool == b.as_bool
      when a.int? && b.int?       then a.as_int == b.as_int
      when a.float? && b.float?   then a.as_float == b.as_float
      when a.int? && b.float?     then a.as_int.to_f64 == b.as_float
      when a.float? && b.int?     then a.as_float == b.as_int.to_f64
      when a.string? && b.string? then a.as_string == b.as_string
      when a.symbol? && b.symbol? then a.as_sym == b.as_sym
      when a.rclass? && b.rclass?
        # Reference identity — `Object.class == Class`, `Foo.superclass
        # == Bar`, etc. RubyClass has no user-facing notion of two
        # DIFFERENT classes comparing equal, so Crystal's default
        # reference `==` on the underlying RubyClass is exactly right,
        # not a placeholder pending a real override.
        a.as_rclass == b.as_rclass
      when a.robject? && b.robject?
        # Reference identity too, for now — real Ruby lets a class
        # override `==` for value-style comparison (two Points with
        # the same x/y), but Adjutant has no user-defined `==`
        # dispatch yet. Matches default Ruby Object#== (identity)
        # before any override, so this is the correct default, not a
        # simplification silently diverging from Ruby.
        a.as_robject == b.as_robject
      when a.array? && b.array?
        # Deep, element-wise equality — real Ruby's Array#== compares
        # length then each element via ITS OWN ==, recursively (so
        # [[1], [2]] == [[1], [2]] is true). Recursing through equal?
        # itself, not Crystal's Array#== on the underlying
        # Array(Value), is what makes that recursion use Adjutant's
        # own equality rules at every level instead of Crystal's.
        aa, ba = a.as_array, b.as_array
        aa.size == ba.size && aa.zip(ba) { |x, y| equal?(x, y) }
      when a.hash? && b.hash?
        # Same reasoning as Array — same key set, and each value equal
        # via equal? (not Crystal's own Hash#==, which would use
        # Value's default struct == instead of this method's rules).
        # Value has no custom hash() override, so key lookup itself
        # still uses Crystal's structural hashing on the ValueRaw
        # union — fine for the Nil/Bool/Int64/Float64/String/Sym keys
        # real scripts actually use; an Array or Hash used AS a key
        # would hash by reference instead of by content, a real but
        # narrow gap worth knowing about rather than a silent one.
        ah, bh = a.as_hash, b.as_hash
        ah.size == bh.size && ah.all? { |k, v| bv = bh[k]?; bv ? equal?(v, bv) : false }
      else false
      end
    end
  end
end
