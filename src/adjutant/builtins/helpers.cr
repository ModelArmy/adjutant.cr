require "../ruby_class"
require "../native_callable"
require "../risk_profile"

module Adjutant::Builtins
  # Use this macro to define native methods that take no arguments, do some
  # calculation with their data and return the result
  # - `arg_as` is the type suffix in `Value#as_XXX` methods
  # - `return_as` is the type suffix in `Value#XXX(...)` constructor methods
  # - `methods` is an array of native methods
  # - `crystal_methods` is an optional array to use when the defined name doesn't match Crystal's stdlib method name
  private macro __define_mapped_methods(cls, interp, self_as, return_as, methods, crystal_methods = nil)
    {% for method, index in methods %}
    define({{cls}}, {{interp}}, {{method.stringify}}) do |args|
      obj = args.first
      val = obj.as_{{self_as}}
      Adjutant::Value.{{return_as}}(
        val.{{crystal_methods ? crystal_methods[index] : method}},
        obj.label) # pass on the risk label
    end
    {% end %}
  end

  # Macro to define a getter method for `name` property, with `default` which can be
  # an expression that uses `obj` for the instance
  private macro __define_getter(cls, interp, name, default = Value.nil_value)
    define({{cls}}, {{interp}}, {{name}}) do |args|
      obj = args.first.as_robject
      name_sym = {{interp}}.symbols.intern({{name}})
      obj.ivars[name_sym.value]? || {{default}}
    end
  end

  # Registers a native method on a builtin RubyClass, keyed by its
  # interned symbol id. `risk` defaults to RiskProfile.none since most
  # builtin methods (arithmetic helpers aside, which don't go through
  # this path at all — see integer.cr) are pure; pass an explicit
  # profile for anything with real side effects (none exist yet among
  # the base types, but e.g. a future File/IO type would).
  def self.define(cls : Adjutant::RubyClass, interp : Adjutant::Interpreter, name : String,
                  risk : Adjutant::RiskProfile = Adjutant::RiskProfile.none, is_private : Bool = false,
                  &block : Array(Adjutant::Value), Adjutant::ScriptProc?, Adjutant::NativeCallContext -> Adjutant::Value) : Nil
    sym_id = interp.symbols.intern(name).value
    cls.define_native_method(sym_id, risk, is_private: is_private) { |args, blk, ncc| block.call(args, blk, ncc) }
  end

  # Registers a native singleton method on a builtin RubyClass, keyed by its
  # interned symbol id. `risk` defaults to RiskProfile.none since most
  # builtin methods (arithmetic helpers aside, which don't go through
  # this path at all — see integer.cr) are pure; pass an explicit
  # profile for anything with real side effects (none exist yet among
  # the base types, but e.g. a future File/IO type would).
  def self.define_singleton(cls : Adjutant::RubyClass, interp : Adjutant::Interpreter, name : String,
                            risk : Adjutant::RiskProfile = Adjutant::RiskProfile.none,
                            &block : Array(Adjutant::Value), Adjutant::ScriptProc?, Adjutant::NativeCallContext -> Adjutant::Value) : Nil
    sym_id = interp.symbols.intern(name).value
    cls.define_native_singleton_method(sym_id, risk) { |args, blk, ncc| block.call(args, blk, ncc) }
  end

  # Shared by Integer#round/#ceil/#floor/#truncate's negative-ndigits
  # form (e.g. `12345.round(-2) == 12300`) — real Ruby rounds an
  # Integer to the nearest power of 10 when ndigits < 0, and returns
  # self unchanged for ndigits >= 0 (an Integer already has no
  # fractional digits, so there's nothing to round at positive
  # precision). Uses Crystal's floor/truncated division directly
  # rather than floating-point scaling, since an Integer input can
  # exceed Float64's exact-integer range — this stays exact.
  #
  # `:round` uses ties-away-from-zero (real Ruby's own default
  # without an explicit `half:` keyword, which isn't supported here).
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

  # Shared by Float#round/#ceil/#floor/#truncate's ndigits form. Real
  # Ruby's rule: ndigits > 0 rounds to that many decimal places and
  # returns a Float; ndigits <= 0 rounds to the nearest power of 10
  # and returns an Integer (same as the no-arg case, which is
  # ndigits == 0). Returns a Value directly (not a bare number) since
  # the return TYPE itself depends on the sign of ndigits, and only
  # the caller has the Value's label to attach.
  #
  # Floating-point scaling (`f * scale`) is real Ruby's own approach
  # too, not an Adjutant shortcut — exact decimal rounding of a
  # binary float is inherently approximate at extreme ndigits either
  # way; not chasing that edge case here.
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

  # Joins the RiskFlowLabel of every Value in `values` into one,
  # seeded from `seed` — shared by every builtin container method that
  # builds a NEW container out of a SUBSET, REORDERING, or COMBINATION
  # of an existing one's contents (array.cr's select/reject/sort/
  # reverse/map, hash.cr's to_a/merge).
  #
  # `seed` matters: per research/IFC_DESIGN.md's Container labeling
  # (Stage 3.5) design, a LabeledArray/LabeledHash carries its OWN
  # accumulated label distinct from any individual element's — e.g. a
  # container explicitly marked via declare_sensitivity at the
  # container level, or one that already lost precision from an
  # earlier partial removal (that design's own "container labels are
  # monotonic, never shrink" rule). A join over only the values
  # actually present would silently drop that container-level taint
  # the moment a script called select/sort/merge/etc. — callers pass
  # the ORIGINAL container's (or containers', for merge) own `.label`
  # as `seed` specifically to carry it forward, matching the design
  # doc's "fails safe rather than silently under-tainting" principle
  # rather than recomputing from contents alone.
  #
  # Generic over WHICH container type is involved (Array or Hash) —
  # nothing here is Array- or Hash-specific, it's a fold over whatever
  # Values the caller collected, which is why this lives here rather
  # than duplicated once per builtin file.
  def self.joined_label(values : Array(Adjutant::Value), seed : Adjutant::RiskFlowLabel? = nil) : Adjutant::RiskFlowLabel?
    values.reduce(seed) { |acc, v| Adjutant::RiskFlowLabel.join(acc, v.label) }
  end

  # A plain, local-to-this-module type name for error messages — NOT a
  # substitute for the real `class`/`is_a?` resolution machinery
  # (Interpreter#builtin_class_for), which needs a full Interpreter
  # and isn't reachable from NativeCallContext. Lives here rather than
  # on Value itself since it's specifically "the name a native
  # method's own error message would use," a native-method-dispatch
  # concern, not a property of Value as a type. Good enough for a
  # TypeError-style message (real Ruby's own wording here is
  # similarly plain, e.g. "no implicit conversion of Integer into
  # Hash"), not intended for anything needing the REAL class object
  # (respond_to?, is_a?, user-defined subclasses, etc).
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
