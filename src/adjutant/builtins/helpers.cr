require "../ruby_class"
require "../native_callable"
require "../risk_profile"

module Adjutant::Builtins
  # Defines argument-free native methods that call the Crystal method
  # of the same name on the receiver and wrap the result:
  #
  #   - `self_as`: the receiver's `Value#as_XXX` suffix
  #   - `return_as`: the result's `Value.XXX` constructor
  #   - `methods`: the names to define
  #   - `crystal_methods`: Crystal names, where they differ
  private macro __define_mapped_methods(cls, interp, self_as, return_as, methods, crystal_methods = nil)
    {% for method, index in methods %}
    define({{ cls }}, {{ interp }}, {{ method.stringify }}) do |args|
      obj = args.first
      val = obj.as_{{ self_as }}
      Adjutant::Value.{{ return_as }}(
        val.{{ crystal_methods ? crystal_methods[index] : method }},
        obj.label) # pass on the risk label
    end
    {% end %}
  end

  # Defines a reader for ivar `name`, returning `default` (which may
  # use `obj`, the receiver) when unset.
  private macro __define_getter(cls, interp, name, default = Value.nil_value)
    define({{ cls }}, {{ interp }}, {{ name }}) do |args|
      obj = args.first.as_robject
      name_sym = {{ interp }}.symbols.intern({{ name }})
      obj.ivars[name_sym.value]? || {{ default }}
    end
  end

  # Registers a native instance method on a builtin class. `risk`
  # defaults to none, since builtin methods are pure.
  def self.define(cls : Adjutant::RubyClass, interp : Adjutant::Interpreter, name : String,
                  risk : Adjutant::RiskProfile = Adjutant::RiskProfile.none, is_private : Bool = false,
                  &block : Array(Adjutant::Value), Adjutant::ScriptProc?, Adjutant::NativeCallContext -> Adjutant::Value) : Nil
    sym_id = interp.symbols.intern(name).value
    cls.define_native_method(sym_id, risk, is_private: is_private) { |args, blk, ncc| block.call(args, blk, ncc) }
  end

  # Registers a native singleton method on a builtin class, as
  # `define` does.
  def self.define_singleton(cls : Adjutant::RubyClass, interp : Adjutant::Interpreter, name : String,
                            risk : Adjutant::RiskProfile = Adjutant::RiskProfile.none,
                            &block : Array(Adjutant::Value), Adjutant::ScriptProc?, Adjutant::NativeCallContext -> Adjutant::Value) : Nil
    sym_id = interp.symbols.intern(name).value
    cls.define_native_singleton_method(sym_id, risk) { |args, blk, ncc| block.call(args, blk, ncc) }
  end

  # Integer rounding to `ndigits` for round, ceil, floor and
  # truncate: unchanged for `ndigits >= 0`, otherwise to a power of
  # ten (`12345.round(-2)` is 12300). Integer arithmetic, so exact at
  # any size. `:round` rounds half away from zero; `half:` isn't
  # supported.
  def self.integer_round_to_power_of_ten(n : Int64, ndigits : Int64, mode : Symbol) : Int64
    return n if ndigits >= 0
    factor = 10_i64 ** (-ndigits)
    case mode
    when :floor
      (n // factor) * factor
    when :ceil
      (-((-n) // factor)) * factor
    when :truncate
      n.tdiv(factor) * factor
    when :round
      if n >= 0
        ((n + factor // 2) // factor) * factor
      else
        (-(((-n) + factor // 2) // factor)) * factor
      end
    else
      n
    end
  end

  # Float rounding to `ndigits` for round, ceil, floor and truncate:
  # a Float for `ndigits > 0`, otherwise an Integer, as in Ruby. Scales
  # by a power of ten, as Ruby does. Returns a Value, since the type
  # depends on `ndigits`.
  def self.float_round_to_power_of_ten(f : Float64, ndigits : Int64, mode : Symbol, label : Adjutant::RiskFlowLabel?) : Adjutant::Value
    scale = 10.0 ** ndigits
    scaled = f * scale
    rounded = case mode
              when :floor    then scaled.floor
              when :ceil     then scaled.ceil
              when :truncate then scaled.trunc
              when :round    then scaled >= 0 ? (scaled + 0.5).floor : (scaled - 0.5).ceil
              else                scaled
              end
    result = rounded / scale
    ndigits > 0 ? Adjutant::Value.float(result, label) : Adjutant::Value.int(result, label)
  end

  # The join of every value's label with `seed`, for a builtin that
  # builds a new container from an existing one's contents. Pass the
  # source container's label as `seed`: it can carry labels no current
  # element does, and dropping them would under-label the result.
  def self.joined_label(values : Array(Adjutant::Value), seed : Adjutant::RiskFlowLabel? = nil) : Adjutant::RiskFlowLabel?
    values.reduce(seed) { |acc, v| Adjutant::RiskFlowLabel.join(acc, v.label) }
  end

  # The type name a native method's error message shows. Not the
  # value's class object; for that, the Interpreter resolves it.
  # ameba:disable Metrics/CyclomaticComplexity - one `when` per Value variant, each a flat one-line case; not tangled branching
  def self.builtin_type_name(v : Adjutant::Value) : String
    case
    when v.null?    then "NilClass"
    when v.bool?    then v.as_bool ? "TrueClass" : "FalseClass"
    when v.int?     then "Integer"
    when v.float?   then "Float"
    when v.string?  then "String"
    when v.symbol?  then "Symbol"
    when v.array?   then "Array"
    when v.hash?    then "Hash"
    when v.proc?    then "Proc"
    when v.rclass?  then "Class"
    when v.robject? then v.as_robject.rclass.name
    else                 "Object"
    end
  end
end
