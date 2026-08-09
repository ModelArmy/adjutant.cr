require "./risk_profile"

module Adjutant
  # A native function paired with its static RiskProfile.
  #
  # This is the single representation for any callable implemented in
  # Crystal rather than script code — currently functions installed via
  # Interpreter#define_native (including those loaded by ScriptModules
  # through ModuleRegistry). Planned: RubyClass native methods for base
  # types (String, Array, Integer, ...) will use the same wrapper, so a
  # risk-manifest walker has exactly one place to look regardless of
  # whether a call resolves to a required module's function or a base
  # type's method.
  #
  # Defaults to RiskProfile.none — most native functions are pure.
  struct NativeCallable
    getter func : NativeFunc
    getter risk : RiskProfile

    # Keyword names this native callable accepts, by name only — no
    # declared defaults (see SCOPE.md/DEVELOPMENT.md's "Native
    # keyword arguments" note): a native function that wants a
    # default builds its own fallback Hash and merges the caller's
    # kwargs over it in Crystal, the same way `assert`
    # (testing/assert_module.cr) already hand-rolls positional
    # presence checks — matching mruby's own `mrb_get_args` kwargs
    # convention (the C function pre-fills defaults itself; the
    # binding machinery only overwrites what the caller actually
    # supplied), not reusing Param/AST-default machinery, which
    # requires compiled bytecode (Compiler#emit_default_prologue) to
    # evaluate and has nothing to run against at a native call site.
    #
    # Defaulted to empty so every existing native registration
    # (define_native_method/define_native_singleton_method/
    # Interpreter#define_native) is unaffected — an empty set means
    # "accepts no kwargs at all," matching today's unconditional
    # reject_kwargs! behavior exactly.
    getter kwarg_names : Set(String)

    def initialize(@func : NativeFunc, @risk : RiskProfile = RiskProfile.none,
                   @kwarg_names : Set(String) = Set(String).new)
    end

    def call(args : Array(Value), blk : ScriptProc?, ctx : NativeCallContext) : Value
      @func.call(args, blk, ctx)
    end
  end
end
