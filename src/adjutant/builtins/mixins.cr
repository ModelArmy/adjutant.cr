require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Registers `Module#include`/`Module#extend` — real Ruby's Module
  # instance methods, not keywords (see token.cr's own comment on why
  # both were removed from the reserved-word table). Registered on
  # Module specifically, not Class or Object: every class's own
  # `rclass` is Class, and `Class.superclass == Module` (see
  # Interpreter#bootstrap_core_hierarchy), so registering them once
  # here makes them available from BOTH `class Foo; include Bar; end`
  # and `module M; include Bar; end` bodies — VM#dispatch_call's
  # self-is-rclass branch walks exactly this chain
  # (`self_rclass.rclass.find_native_method`) for a bare call made
  # from inside either kind of body.
  #
  # STEP 2 of the include-support build-out (see SCOPE.md's git
  # history): `include` registers the module into `included_modules`
  # — actual METHOD RESOLUTION honoring it (RubyClass#find_method/
  # find_native_method walking included_modules, not just
  # superclass) is Step 3, not yet done as of this file landing.
  # `include`-ing a module here is consequently a real no-op as far
  # as calling any of its methods goes, until that step lands — the
  # registration itself is complete and tested on its own terms.
  #
  # STEP 2 of the SEPARATE extend-support build-out (this session):
  # `extend` is registered the identical way, into `extended_modules`
  # instead — same "registration only, no resolution yet" shape.
  # Actual resolution (RubyClass#find_singleton_method/
  # find_native_singleton_method walking extended_modules) is that
  # build-out's own Step 3.
  def self.register_module_methods(mod_cls : Adjutant::RubyClass, interp : Adjutant::Interpreter) : Nil
    define(mod_cls, interp, "include") do |args, _blk, ncc|
      # Reached via `dispatch_call`'s implicit-self/self-is-rclass
      # branch (a bare call inside a class/module body) — that path
      # never prepends a receiver into `args` the way explicit-
      # receiver dispatch does (see `array.cr`'s own `args.first`
      # convention, which does NOT apply here). `self` comes from
      # `ncc.self_val` instead (see `NativeCallContext#self_val`'s own
      # comment) — `args.first` here is genuinely the module being
      # mixed in, not a receiver.
      #
      # No validation that the argument is actually a module (vs. an
      # ordinary class, which real Ruby rejects with TypeError) —
      # matches this codebase's existing convention for native
      # methods generally (see helpers.cr's __define_mapped_methods
      # and every builtin method that calls `.as_array`/`.as_hash`
      # etc. directly with no guard): a script passing the wrong
      # shape gets a low-level failure, not a curated one, same
      # risk-tolerance level as everything else here. Worth
      # revisiting if this specific case turns out to be a common
      # mistake in practice.
      including = ncc.self_val.as_rclass
      mod = args.first.as_rclass
      including.include_module(mod)
      ncc.self_val
    end

    define(mod_cls, interp, "extend") do |args, _blk, ncc|
      # Same shape as "include" above — same reasoning applies
      # unchanged (self via ncc.self_val, no argument validation).
      # Only real difference: extend_module (extended_modules), not
      # include_module (included_modules) — see RubyClass#
      # extended_modules' own comment for why these are genuinely
      # separate lists, not a shared one.
      extending = ncc.self_val.as_rclass
      mod = args.first.as_rclass
      extending.extend_module(mod)
      ncc.self_val
    end
  end
end
