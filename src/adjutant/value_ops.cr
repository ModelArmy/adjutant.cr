module Adjutant
  # The type dispatch behind every operator on builtin values (`+`,
  # `-`, `*`, `/`, `%`, `&`, `|`, `^`, `<<`, `>>`, the comparisons and
  # `==`), with no VM or Interpreter state. An object operand is
  # dispatched by the VM before reaching here; one that does reach
  # here gets the "no valid conversion" result.
  #
  # The arithmetic methods take an `on_error` proc rather than
  # raising, since only the VM can build a script-catchable error
  # object. `compare` and `equal?` never fail: an unrecognised pair is
  # false, as Ruby's `<=>` gives nil and `==` false.
  module ValueOps
    # Raises an error of the named class ("TypeError",
    # "ZeroDivisionError") with a message.
    alias OnError = String, String -> NoReturn

    # ameba:disable Metrics/CyclomaticComplexity
    def self.add(a : Value, b : Value, on_error : OnError) : Value
      case
      when a.int? && b.int?       then Value.int(a.as_int + b.as_int)
      when a.float? && b.float?   then Value.float(a.as_float + b.as_float)
      when a.int? && b.float?     then Value.float(a.as_int.to_f64 + b.as_float)
      when a.float? && b.int?     then Value.float(a.as_float + b.as_int.to_f64)
      when a.string? && b.string? then Value.string(a.as_string + b.as_string)
      when a.array? && b.array?
        # A new Array; neither operand changes. The VM sets the
        # result's label.
        Value.new(LabeledArray.new(a.as_array.dup_items + b.as_array.dup_items), nil)
      else
        on_error.call("cannot add #{a} and #{b}", "TypeError")
      end
    end

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
        on_error.call("type error in arithmetic", "TypeError")
      end
    end

    def self.div(a : Value, b : Value, on_error : OnError) : Value
      case
      when a.int? && b.int?
        on_error.call("divided by 0", "ZeroDivisionError") if b.as_int == 0
        Value.int(a.as_int // b.as_int)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        Value.float(fa / fb)
      else
        on_error.call("type error in division", "TypeError")
      end
    end

    def self.mod(a : Value, b : Value, on_error : OnError) : Value
      on_error.call("divided by 0", "ZeroDivisionError") if (b.int? && b.as_int == 0) || (b.float? && b.as_float == 0.0)
      case
      when a.int? && b.int? then Value.int(a.as_int % b.as_int)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        Value.float(fa % fb)
      else
        on_error.call("type error in modulo", "TypeError")
      end
    end

    def self.int_op(a : Value, b : Value, op : Symbol, on_error : OnError) : Value
      on_error.call("bitwise op requires Integer", "TypeError") unless a.int? && b.int?
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

    # Integer shift, or Array append. Separate from `int_op`, so `&`,
    # `|`, `^` and `>>` stay Integer-only.
    def self.shl(a : Value, b : Value, on_error : OnError) : Value
      if a.array?
        # Appends to `a` in place and returns it, so `arr << 1 << 2`
        # chains; the VM's relabel then joins `b`'s label into the
        # array's.
        a.as_array.push(b)
        a
      else
        int_op(a, b, :<<, on_error)
      end
    end

    # Never fails: an unrecognised pair is false.
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

    # True when `compare` and `spaceship` order this pair: two
    # numbers, or two Strings. Two Arrays are ordered only by
    # `VM#spaceship`.
    def self.orderable?(a : Value, b : Value) : Bool
      ((a.int? || a.float?) && (b.int? || b.float?)) || (a.string? && b.string?)
    end

    def self.spaceship(a : Value, b : Value) : Int32?
      case
      when a.int? && b.int?
        a.as_int <=> b.as_int
      when (a.int? || a.float?) && (b.int? || b.float?)
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        fa <=> fb
      when a.string? && b.string?
        a.as_string <=> b.as_string
      end
    end

    # Container pairs whose comparison is in progress, by identity.
    alias Comparing = Set({UInt64, UInt64})

    # Never fails: an unrecognised pair is false. A pair of containers
    # met again while it is still being compared counts as equal, as
    # in Ruby, so a self-containing Array or Hash compares without
    # recursing forever. Callers leave `comparing` out.
    # ameba:disable Metrics/CyclomaticComplexity
    def self.equal?(a : Value, b : Value, comparing : Comparing? = nil) : Bool
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
        # Identity.
        a.as_rclass == b.as_rclass
      when a.robject? && b.robject?
        # Identity. An object with `<=>` gets `==` from it in
        # `VM#values_equal?`, which never reaches here for one.
        a.as_robject == b.as_robject
      when a.array? && b.array? then arrays_equal?(a.as_array, b.as_array, comparing)
      when a.hash? && b.hash?   then hashes_equal?(a.as_hash, b.as_hash, comparing)
      else                           false
      end
    end

    # The same object, or the same length and each element equal by
    # `equal?`.
    private def self.arrays_equal?(aa : LabeledArray, ba : LabeledArray, comparing : Comparing?) : Bool
      return true if aa.same?(ba)
      return false unless aa.size == ba.size
      guard_pair(aa.object_id, ba.object_id, comparing) do |inner|
        aa.zip(ba) { |x, y| equal?(x, y, inner) }
      end
    end

    # The same object, or the same keys and each value equal by
    # `equal?`.
    private def self.hashes_equal?(ah : LabeledHash, bh : LabeledHash, comparing : Comparing?) : Bool
      return true if ah.same?(bh)
      return false unless ah.size == bh.size
      guard_pair(ah.object_id, bh.object_id, comparing) do |inner|
        ah.all? do |k, v|
          bv = bh[k]?
          bv ? equal?(v, bv, inner) : false
        end
      end
    end

    # Runs the comparison of one container pair with the pair marked
    # in progress; true without running it if the pair already is.
    private def self.guard_pair(a_id : UInt64, b_id : UInt64, comparing : Comparing?, & : Comparing -> Bool) : Bool
      in_progress = comparing || Comparing.new
      pair = {a_id, b_id}
      return true if in_progress.includes?(pair)
      in_progress << pair
      begin
        yield in_progress
      ensure
        in_progress.delete(pair)
      end
    end
  end
end
