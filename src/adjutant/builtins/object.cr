require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Registers `Object`'s own native `to_s`/`inspect` — the DEFAULT
  # every class inherits unless it defines its own, exactly like real
  # Ruby's `Object#to_s`/`Object#inspect`. Step 1 of the `to_s`/
  # `inspect` overridability work (see SCOPE.md's "Object model"
  # group and DEVELOPMENT.md for the full plan) — everything else
  # (Array/Hash/Range's own real renderers, cycle detection, wiring
  # `puts`/`print`/`p` to real dispatch instead of a hardcoded
  # Crystal-level call) builds on THIS existing first, since without
  # a real `Object#to_s`/`#inspect` to fall back to, nothing else has
  # a base case to inherit from.
  #
  # Deliberately NOT called from `bootstrap_builtin_classes` alongside
  # Integer/Float/... (interpreter.cr) — `Object` itself is built
  # earlier, in `bootstrap_core_hierarchy`, before `bootstrap_builtin_
  # classes` even runs (see that method's own comment on why: `@main`
  # needs `object_class` to already exist). This file's entry point is
  # called separately, right after `bootstrap_core_hierarchy`,
  # against the ALREADY-CONSTRUCTED `object_class` — it doesn't build
  # a new RubyClass the way `bootstrap_array`/`bootstrap_range`/etc.
  # do, it adds native methods to one that already exists.
  #
  # `Object#inspect`'s default lists instance variables, matching real
  # Ruby's own default (`#<Foo:0x... @x=1, @y="hi">`) — WITHOUT the
  # `0x...` memory address. Real Ruby's address has no debugging value
  # here (it's not stable across runs, nothing script-side can
  # correlate it against, and Adjutant doesn't expose real memory
  # addresses to begin with) — the address is the one deliberate
  # deviation from real Ruby's exact format in this file; the
  # class-name-plus-ivars structure it wraps is otherwise faithful.
  # Each ivar's OWN value is rendered via a REAL recursive
  # `ncc.call_method(ivar_value, "inspect", [])` call, not a
  # hand-rolled recursion — so an ivar holding, say, an Array whose
  # own `#inspect` hasn't been built yet (later step) still renders
  # via WHATEVER that type's current `#inspect` resolves to today,
  # and automatically improves for free once that step lands, with no
  # further change needed here.
  def self.bootstrap_object_methods(interp : Adjutant::Interpreter, cls : Adjutant::RubyClass) : Nil
    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.to_s)
    end

    # `recv.as_robject?` (nilable) — NOT `as_robject`. Every scalar
    # type (Integer, Float, String, ...) has its OWN `to_s` already
    # (see builtins/integer.cr/float.cr/string.cr), so `to_s` above
    # never reaches a non-RubyObject receiver in practice — but NO
    # type has its own `inspect` yet, as of this file (Array/Hash's
    # own real `inspect` is a later step in this same plan). Until
    # then, `5.inspect`, `"a".inspect`, `[1, 2].inspect` all resolve
    # HERE, by inheritance, with a receiver that is Int64/String/a
    # LabeledArray — none of them a RubyObject. Falling back to the
    # EXISTING `Value#inspect` (value.cr) for that case reproduces
    # exactly what those calls already did before this file existed —
    # not a regression, just not yet the real per-type implementation
    # a later step gives them.
    define(cls, interp, "inspect") do |args, _blk, ncc|
      recv = args.first
      obj = recv.as_robject?
      if obj.nil?
        Adjutant::Value.string(recv.inspect)
      elsif obj.ivars.empty?
        Adjutant::Value.string(recv.to_s)
      else
        pairs = obj.ivars.map do |sym_id, ivar_value|
          name = interp.symbols.name_for(sym_id) || "?"
          inspected = ncc.call_method(ivar_value, "inspect", [] of Adjutant::Value)
          "#{name}=#{inspected.as_string}"
        end
        Adjutant::Value.string("#<#{obj.rclass.name} #{pairs.join(", ")}>")
      end
    end
  end
end
