require "json"
require "../ruby_class"
require "../diagnostic"

module Adjutant
  module Legate
    module Helpers
      # Builds the bare `Legate` module itself — no classes nested yet.
      # Called exactly once (Interpreter#bootstrap_error_classes); every
      # other Legate submodule (Exceptions, the six value types, and
      # eventually the verb surface) receives the SAME returned RubyClass
      # instance and nests its own classes into it via `nest` below,
      # rather than each building its own competing "Legate" module.
      def self.build_module(interp : Interpreter) : RubyClass
        legate = RubyClass.new("Legate", nil, is_module: true)
        legate.rclass = interp.class_class
        legate
      end

      # Builds a class nested under `parent`'s own namespace —
      # `Legate::Foo` reachable via real `ConstPath` resolution
      # (`Op::GetConstantFrom`, vm.cr), the same mechanism a
      # script-written `class A; class B; end; end` uses for `A::B`.
      # NOT a flat "Legate::Foo" global name — see
      # Legate::Exceptions.bootstrap's own original comment (the first
      # place this reasoning was worked out) for the full explanation
      # of why: short name only, `lexical_parent` set to `parent`,
      # inserted into `parent`'s own `constants` table keyed by that
      # short name's interned symbol — `qualified_name` then derives
      # "Legate::Foo" for display by walking `lexical_parent`, for
      # free, the same as any script-defined nested class.
      #
      # Shared across every Legate submodule (exceptions, value types,
      # future verbs) since the nesting mechanics are identical
      # regardless of what's being nested — only `superclass`/
      # `is_module` vary per caller.
      def self.nest(parent : RubyClass, interp : Interpreter, name : String,
                    superclass : RubyClass? = nil, is_module : Bool = false) : RubyClass
        cls = RubyClass.new(name, superclass, is_module: is_module)
        cls.rclass = interp.class_class
        cls.lexical_parent = parent
        parent.constants[interp.symbols.intern(name).value] = Value.rclass(cls)
        cls
      end

      # Looks up an already-nested class by short name — e.g.
      # `Helpers.fetch(legate, interp, "Malformed")` to get the real
      # `Legate::Malformed` RubyClass reference a native method needs
      # for `NativeCallContext#raise_error_class` (which takes the
      # class directly, not a name — see that method's own comment
      # for why). Raises a loud `InternalError` rather than returning
      # nil on a miss: every caller of this expects the class to
      # already exist (built earlier in the same `bootstrap_legate`
      # call, per `Interpreter#bootstrap_legate`'s fixed ordering), so
      # a miss here means the bootstrap ORDER is wrong, not that the
      # caller should handle an absent class gracefully.
      def self.fetch(parent : RubyClass, interp : Interpreter, name : String) : RubyClass
        val = parent.constants[interp.symbols.intern(name).value]?
        val.try(&.as_rclass?) || raise InternalError.new("Legate::#{name} not yet bootstrapped when Legate::Helpers.fetch(#{name.inspect}) was called — check bootstrap_legate's ordering")
      end

      # Crystal's `JSON::Any` -> Adjutant `Value`, recursively.
      # EXTRACTED here 2026-08-26 (was `Legate::Response`'s own private
      # `json_to_value`, response.cr) so `Legate::Records`'s `:jsonl`
      # format could reuse it without a second, silently-drifting copy
      # of the same recursive-conversion logic — `Response#json` now
      # calls this shared version too, unchanged in behavior. `label`
      # is applied to EVERY constructed piece, leaves and containers
      # alike — decoding JSON doesn't create new information, only
      # reshapes existing (possibly tainted) text, so every part of
      # the result carries the SAME taint the source string already
      # had. `JSON::Any#raw` is the underlying Crystal value; each
      # variant maps onto the ordinary Value constructor for that
      # shape — Hash keys are always JSON strings, matching how
      # Adjutant's own Hash already uses String-keyed Value pairs
      # elsewhere. Hash KEYS stay unlabeled — metadata identifying
      # WHICH piece of data this is, not itself extracted data, same
      # "data vs metadata" rule every other Legate value type's own
      # comment documents.
      def self.json_to_value(interp : Interpreter, json : ::JSON::Any, label : RiskFlowLabel?) : Value
        case raw = json.raw
        when Nil     then Value.nil_value
        when Bool    then Value.bool(raw)
        when Int64   then Value.int(raw, label)
        when Float64 then Value.float(raw, label)
        when String  then Value.string(raw, label)
        when Array(::JSON::Any)
          Value.new(LabeledArray.new(raw.map { |item| json_to_value(interp, item, label) }, label), label)
        when Hash(String, ::JSON::Any)
          entries = {} of Value => Value
          raw.each { |key, value| entries[Value.string(key)] = json_to_value(interp, value, label) }
          Value.new(LabeledHash.new(entries, label), label)
        else
          Value.nil_value
        end
      end
    end
  end
end
