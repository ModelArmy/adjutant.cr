require "./symbol_table"
require "./lexer"
require "./parser"
require "./compiler"
require "./bytecode"
require "./module_registry"
require "./vm"
require "./effect_handler"
require "./risk_profile"
require "./risk_flow_policy"
require "./risk_flow_decision"
require "./native_callable"
require "./native_call_context"
require "./native_function_call"
require "./builtins"
require "./legate"

module Adjutant
  # Top-level entry point for the Adjutant interpreter.
  #
  # Owns the SymbolTable (shared across all compilations), the
  # ModuleRegistry (capability manifest), and creates a fresh VM
  # per execution. The EffectHandler defines the containment boundary
  # for physical effects.
  #
  # `risk_flow_policy` and `on_risk_flow_decision` are both required,
  # always — there is no default that means "skip risk assessment."
  # An embedder who genuinely wants no risk assessment must say so
  # explicitly via `RiskFlowPolicy.reject_all` (safe default: reject
  # rather than silently allow); `on_risk_flow_decision` is required
  # even then, so the constructor's shape doesn't depend on what's
  # inside the policy (Crystal can't express "required only if the
  # policy could ever produce Ask" as a type constraint, so requiring
  # it unconditionally is what makes this a real, checked guarantee
  # rather than a runtime one). See research/IFC_DESIGN.md's
  # enforcement design notes.
  #
  # Usage:
  #   effect  = TestEffectHandler.new
  #   interp  = Interpreter.new(
  #     effect: effect,
  #     risk_flow_policy: RiskFlowPolicy.reject_all,
  #     on_risk_flow_decision: ->(req : RiskFlowDecisionRequest) { RiskFlowDecision::Reject },
  #   )
  #   interp.modules.register("agent/io") { |i| ... }
  #   interp.eval("require \"agent/io\"\nputs(42)")
  class Interpreter
    getter symbols : SymbolTable
    getter modules : ModuleRegistry
    getter effect : EffectHandler?
    getter limits : ExecutionLimits
    getter risk_flow_log : RiskFlowLog
    getter risk_flow_policy : RiskFlowPolicy
    getter on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision

    # Legate's own policy/enforcement pair, threaded through the same
    # way risk_flow_policy is (a safe, explicit default rather than an
    # implicit allow-everything one) — `grants` is fixed at
    # construction (LEGATE.md §7's "fixed before execution, never
    # escalatable"), and `broker` is the ONE Broker instance every
    # Legate verb bootstrap (Legate::Verbs::*) closes over, so budget/
    # audit state genuinely accumulates across the whole run rather
    # than resetting per call. Unlike risk_flow_policy, `grants`
    # DOES have a default (`Grants.deny_all`) rather than being
    # required — an embedder not using Legate's effectful verbs at
    # all (many scripts won't) shouldn't have to think about grants
    # to construct an Interpreter; the default is still the fully
    # closed policy, not a silent allow-everything one, so nothing
    # about "safe by default" is lost.
    getter grants : Legate::Grants
    getter broker : Legate::Broker

    # Source of every script this interpreter has parsed, keyed by
    # filename. Populated by `eval`/`compile`, including files pulled
    # in by `require`, whose diagnostics name a different file than
    # the top-level script.
    getter sources : SourceMap = SourceMap.new

    # Where a reader is told to report an internal (`I`-series) error.
    # Defaults upstream; a host embedding Adjutant should point this at
    # wherever ITS users should report problems, since those users have
    # no relationship with this project.
    property report_url : String = DiagnosticRenderer::DEFAULT_REPORT_URL

    # `self` at the top level of a script — a real RubyObject whose
    # class is Object, matching real Ruby's actual `main` (not a
    # simplification of it: a bare top-level `def` genuinely becomes
    # a method of Object this way — see Op::DefMethod — callable from
    # ANY object anywhere, not confined to some top-level-only table,
    # exactly like real Ruby's top-level defs becoming private
    # instance methods of Object). One `main` per Interpreter, reused
    # across every `eval` call on it, so top-level defs persist across
    # eval calls the same way they always have (this is unrelated to,
    # and unaffected by, the 2026-07-15 fix that made top-level plain
    # VARIABLES scoped per-eval-call — methods living on Object were
    # always meant to persist).
    getter main : RubyObject

    def initialize(
      @risk_flow_policy : RiskFlowPolicy,
      @on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision,
      @effect : EffectHandler? = nil,
      @limits : ExecutionLimits = ExecutionLimits.new,
      risk_flow_tracking : Bool = false,
      @grants : Legate::Grants = Legate::Grants.deny_all,
    )
      @symbols = SymbolTable.new
      @modules = ModuleRegistry.new
      @globals = {} of Int32 => Value
      @risk_flow_log = RiskFlowLog.new(enabled: risk_flow_tracking)
      @broker = Legate::Broker.new(@grants)
      bootstrap_core_hierarchy
      # @main must be assigned here, right after object_class first
      # becomes valid — NOT after bootstrap_error_classes/
      # bootstrap_builtin_classes, both of which pass `self` outward
      # (e.g. `Builtins.bootstrap_range(self)`), and Crystal requires
      # every non-nilable ivar assigned before `self` escapes the
      # constructor in any way, not just before it returns.
      @main = RubyObject.new(object_class)
      # Same ordering reasoning as bootstrap_builtin_classes just
      # below: Object's OWN native methods (to_s/inspect — the
      # default every other type inherits) need object_class to
      # already exist, which it does as of the line above. Ahead of
      # bootstrap_builtin_classes specifically only because it's
      # logically prerequisite to it, not because anything currently
      # in bootstrap_builtin_classes depends on it directly.
      Builtins.bootstrap_object_methods(self, object_class)
      bootstrap_builtin_classes
    end

    # Register an already-built RubyClass into @globals under its own
    # name — the same namespace a top-level `class Foo` writes to via
    # Op::SetConstant. Used by Builtins to install base types (Integer,
    # String, ...); see bootstrap_error_classes for the sibling path
    # that builds-and-registers exception classes in one step.
    def define_global_class(cls : RubyClass) : RubyClass
      sym = @symbols.intern(cls.name)
      @globals[sym.value] = Value.rclass(cls)
      cls
    end

    # Read a global variable by name — reflects current interpreter state.
    def get_global(name : String) : Value
      sym = @symbols.lookup(name)
      return Value.nil_value unless sym
      @globals[sym.value]? || Value.nil_value
    end

    # Parse a script to an AST without compiling or running it.
    #
    # This is the entry point for the assess-then-decide workflow: a
    # host that wants to run `RiskWalker` over a script before choosing
    # whether to execute it needs the `Body`, not a result.
    #
    # Prefer this over constructing a `Parser` directly. Both parse
    # identically, but this registers the source first, so a diagnostic
    # raised by ANY later phase can quote the offending line. A host
    # that goes straight to `Parser` gets diagnostics with a location
    # and an explanation but no source snippet — the failure is silent
    # and looks like the feature simply not working.
    def parse(source : String, filename : String = "<parse>") : Body
      parse(IO::Memory.new(source), filename)
    end

    # ditto, from an IO stream.
    def parse(io : IO, filename : String = "<parse>") : Body
      parser = Parser.new(io, filename)
      # Registered BEFORE parsing, so a ParseError gets a snippet too —
      # not only the errors from phases that run after parsing.
      sources.register(filename, parser.source)
      parser.parse
    end

    # Parse, compile, and execute a source string.
    def eval(source : String, filename : String = "<eval>") : Value
      eval(IO::Memory.new(source), filename)
    end

    # Parse, compile, and execute from an IO stream.
    def eval(io : IO, filename : String = "<eval>") : Value
      eval(parse(io, filename), filename)
    end

    # Compile and execute an already-parsed script.
    #
    # Completes the assess-then-decide workflow: `parse`, walk the
    # `Body` for risk, decide, then execute THAT body — with no second
    # parse, and no window in which the text could differ from what was
    # assessed.
    #
    # `filename` is required, unlike the other overloads. A `Body` does
    # not record which file it came from, and defaulting would key VM
    # frames and diagnostics to a name the source was never registered
    # under — losing snippets precisely when something has gone wrong.
    # Pass the same name given to `parse`.
    def eval(body : Body, filename : String) : Value
      chunk, local_count = Compiler.compile(body, @symbols)
      vm = make_vm
      vm.run(chunk, filename, local_count)
    end

    # Compile a source string without executing — for pre-validation.
    def compile(source : String, filename : String = "<compile>") : Chunk
      compile(IO::Memory.new(source), filename)
    end

    def compile(io : IO, filename : String = "<compile>") : Chunk
      chunk, _local_count = Compiler.compile(parse(io, filename), @symbols)
      chunk
    end

    # Render a diagnostic-carrying error as text, with the offending
    # source line and carets where position information allows.
    #
    # Returns nil when the error carries no diagnostic — which means the
    # SCRIPT raised it (`raise "boom"`, a re-raise, the builtin `raise`)
    # rather than Adjutant reporting a failure it classified.
    #
    # That nil is permanent and load-bearing, not scaffolding left over
    # from the migration. Callers should fall back to `message`, which
    # is the script author's own wording and the only sensible thing to
    # show. See `RuntimeError#diagnostic`.
    def render_error(error : ParseError | CompileError | RuntimeError |
                             HostArgumentError | HostStateError | InternalError |
                             AmbiguousRiskFlowPolicyError,
                     format : DiagnosticRenderer::Format = DiagnosticRenderer::Format::Markdown,
                     filename : String? = nil) : String?
      diag = error.diagnostic
      return nil unless diag
      DiagnosticRenderer.new(sources, report_url).render(diag, format, filename)
    end

    # Called by VM when a script issues `require "path"`.
    def require_module(path : String, filename : String) : Value
      # Try registered script modules first
      return Value.bool(true) if @modules.require(path, self)

      # Fall back to VFS source files
      if ef = @effect
        if src = ef.vfs_read(path)
          eval(IO::Memory.new(src), path)
          return Value.bool(true)
        end
      end

      raise RuntimeError.new(
        Diagnostic.new(
          code: "R010",
          primary: Span.new(line: 0, filename: filename),
          data: {"path" => path}
        ),
        filename,
        0
      )
    end

    # Install a native function as a global callable from scripts with arguments array, block if any, and
    # a `NativeCallContext` that can be used to invoke the block.
    #
    # `risk` declares the function's static side-effect profile — see
    # RiskProfile. Defaults to RiskProfile.none (pure, no side effects),
    # correct for the common case; pass an explicit profile for any
    # function with file, network, process, or environment effects.
    #
    # Registers into Object's OWN native_methods table — not a
    # separate top-level-only table — matching real Ruby, where
    # Kernel methods (puts, require, ...) are technically private
    # instance methods reachable from any object. This is what makes
    # a native function callable via implicit self from anywhere,
    # the same mechanism a bare top-level `def` uses (see
    # Op::DefMethod / dispatch_call's implicit-self step).
    #
    # `kwarg_names` declares which keyword names this function accepts
    # (see NativeCallable#kwarg_names) — empty by default, matching
    # every pre-existing `define_native` call. A function that accepts
    # kwargs reads them via `ncc.kwargs` (NativeCallContext) inside
    # the block; NativeFunc's own signature is unchanged, so this is
    # opt-in per function, not a blast-radius change to every existing
    # native function body.
    # `private` — opt-in, default false; a native function registering
    # itself private (matching real Ruby's own `Kernel` methods, most
    # of which are private) is a deliberate per-function choice, not
    # something flipped globally here. No existing `define_native`
    # call site passes it, so no existing native function's behavior
    # changes by this parameter existing.
    def define_native(name : String, risk : RiskProfile = RiskProfile.none, kwarg_names : Set(String) = Set(String).new, is_private : Bool = false,
                      &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      sym = @symbols.intern(name)
      object_class.define_native_method(sym.value, risk, kwarg_names, is_private: is_private, &block)
    end

    # Look up a native callable by symbol ID — called by VM dispatch.
    # Returns both the function and its RiskProfile. Delegates to
    # Object's own native_methods table (see define_native above).
    def native_callable(sym_id : Int32) : NativeCallable?
      object_class.native_methods[sym_id]?
    end

    # Look up a builtin type's RubyClass by the runtime kind of a Value
    # (e.g. Integer for an int Value) — used by is_a?, .class, and
    # respond_to?, since builtin values aren't RubyObjects and so carry
    # no rclass reference of their own to walk. Returns nil for a
    # receiver kind with no builtin RubyClass yet.
    #
    # `true`/`false` resolve to two DISTINCT classes (TrueClass,
    # FalseClass) — real Ruby has no shared Boolean, so this checks
    # `as_bool` specifically rather than treating `bool?` as one kind.
    def builtin_class_for(val : Value) : RubyClass?
      name = case
             when val.null?   then "NilClass"
             when val.bool?   then val.as_bool ? "TrueClass" : "FalseClass"
             when val.int?    then "Integer"
             when val.float?  then "Float"
             when val.string? then "String"
             when val.array?  then "Array"
             when val.hash?   then "Hash"
             when val.symbol? then "Symbol"
             else                  return nil
             end
      sym = @symbols.lookup(name)
      return nil unless sym
      @globals[sym.value]?.try(&.as_rclass?)
    end

    # The three core classes, reachable by name once
    # bootstrap_core_hierarchy has run (always true after
    # Interpreter#initialize returns — these are looked up, not
    # cached, so a script's own accidental reassignment of the
    # constant would be visible here too, same as any other global).
    def object_class : RubyClass
      @globals[@symbols.intern("Object").value].as_rclass
    end

    def class_class : RubyClass
      @globals[@symbols.intern("Class").value].as_rclass
    end

    def module_class : RubyClass
      @globals[@symbols.intern("Module").value].as_rclass
    end

    # General-purpose counterpart to builtin_class_for above, for the
    # (rarer) case where a native method needs another already-
    # registered builtin class BY NAME rather than by a Value's kind —
    # e.g. Regexp#match constructing a MatchData RubyObject needs the
    # MatchData RubyClass itself, and there's no Value kind to derive
    # it from the way builtin_class_for does for Integer/String/etc.
    # Returns nil for an unregistered name rather than raising, same
    # as builtin_class_for, since "not registered yet" is a normal
    # bootstrap-ordering state, not necessarily a bug.
    def find_builtin_class(name : String) : RubyClass?
      sym = @symbols.lookup(name)
      return nil unless sym
      @globals[sym.value]?.try(&.as_rclass?)
    end

    private def make_vm : VM
      VM.new(@symbols, @limits, @effect, self, @globals, @risk_flow_log, @risk_flow_policy, @on_risk_flow_decision)
    end

    # Bootstraps the three classes at the root of the hierarchy —
    # Object, Class, Module — which have a genuine circular
    # dependency in real Ruby and can't be built in a single pass:
    # Object.rclass == Class, Class.superclass == Module,
    # Module.rclass == Class, and Class.rclass == Class itself
    # (self-referential). Resolved the way CRuby's own bootstrap does
    # it — allocate all three with nil links first, then patch the
    # real cycle in once all three exist. Every OTHER class's
    # `superclass`/`rclass` defaulting (see define_builtin_class, and
    # Op::MakeClass/Op::MakeModule for script-defined classes) depends
    # on this having already run.
    #
    # `Class.new`/`Module.new` (dynamically defining a class/module at
    # runtime, optionally from a block) are explicitly out of scope —
    # see UNSUPPORTED.md's U002. This
    # bootstrap only needs Class/Module to EXIST as real RubyClasses
    # for `.class`/`is_a?`/`ancestors` to work correctly; they're not
    # meant to be instantiable from script. Until 2026-07-27 that was
    # only true by convention — nothing actually stopped `Class.new`/
    # `Module.new` from falling through to the generic
    # construct_object path and silently succeeding, producing a bare,
    # non-functional object. `uninstantiable: true` here now makes
    # `VM#construct` raise a clear error instead (see RubyClass#
    # uninstantiable? and construct's own guard).
    private def bootstrap_core_hierarchy : Nil
      mod_cls = RubyClass.new("Module", nil, is_module: false, uninstantiable: true)
      class_cls = RubyClass.new("Class", nil, is_module: false, uninstantiable: true)
      obj_cls = RubyClass.new("Object", nil, is_module: false)

      # Real Ruby: Class.superclass == Module, Module.superclass ==
      # Object (Object.superclass == BasicObject in real Ruby;
      # Adjutant has no BasicObject, so Object's superclass stays nil
      # as the deliberate root). Module's own link was missing
      # entirely before — Module.superclass was nil, breaking the
      # chain a module needs to reach Object's methods (see
      # dispatch_call's implicit-self step: when self is a RubyClass,
      # e.g. inside a `module M` body, finding a receiverless native
      # method like `puts` requires walking self.rclass's (M.rclass
      # == Module's) OWN superclass chain up to Object, not M's own
      # (modules have no superclass of their own in real Ruby at
      # all) — that chain was broken at its very first link without
      # this).
      class_cls.superclass = mod_cls
      mod_cls.superclass = obj_cls
      obj_cls.rclass = class_cls
      class_cls.rclass = class_cls
      mod_cls.rclass = class_cls

      define_global_class(mod_cls)
      define_global_class(class_cls)
      define_global_class(obj_cls)
    end

    # Registers the builtin exception class hierarchy directly into
    # @globals — the same namespace a top-level `class Foo` writes to
    # via Op::SetConstant — so `raise SomeError` and a bare reference
    # to `SomeError` both resolve correctly. Called once per
    # Interpreter; @globals is shared with every VM it creates, and
    # persists across eval calls on the same interpreter.
    #
    # rescue ClassName filtering (matching a raised object's class,
    # or an ancestor, against the rescue clause) is not yet
    # implemented — this hierarchy exists so `raise`/`.message` work
    # and so that filtering has real classes to check against later.
    private def bootstrap_error_classes : Nil
      standard_error = nil
      Builtins.bootstrap_exception_and_subclasses(self) do |cls|
        standard_error = cls if cls.name == "StandardError"
        register_builtin_class(cls)
      end
      unless standard_error
        raise InternalError.new("StandardError not bootstrapped before Legate::Exceptions.bootstrap ran")
      end
      bootstrap_legate(standard_error)
    end

    # Builds the `Legate` module once (Legate::Helpers.build_module)
    # and populates it — exception tier first (needs `standard_error`,
    # just built above), then every value type. Each submodule nests
    # its own classes into the SAME shared `legate` instance via
    # `Legate::Helpers.nest`, rather than each building a competing
    # "Legate" module of its own — see that helper's own comment for
    # the full ConstPath-resolution reasoning. Only `legate` itself
    # gets registered as a top-level global (via `define_global_class`,
    # NOT `register_builtin_class` — the latter defaults an unset
    # `superclass` to `Object`, correct for a builtin CLASS but wrong
    # for a module).
    private def bootstrap_legate(standard_error : RubyClass) : Nil
      legate = Legate::Helpers.build_module(self)
      Legate::Exceptions.bootstrap(self, legate, standard_error)
      Legate::Path.bootstrap(self, legate)
      Legate::Stat.bootstrap(self, legate)
      Legate::Entry.bootstrap(self, legate)
      Legate::Match.bootstrap(self, legate)
      Legate::Response.bootstrap(self, legate)
      Legate::Exit.bootstrap(self, legate)
      Legate::Chunk.bootstrap(self, legate)
      Legate::Stream.bootstrap(self, legate)
      Legate::Verbs::Stat.bootstrap(self, legate, @broker)
      Legate::Verbs::Read.bootstrap(self, legate, @broker)
      Legate::Verbs::List.bootstrap(self, legate, @broker)
      Legate::Verbs::Bytes.bootstrap(self, legate, @broker)
      Legate::Verbs::Lines.bootstrap(self, legate, @broker)
      Legate::Verbs::Records.bootstrap(self, legate, @broker)
      Legate::Verbs::Grep.bootstrap(self, legate, @broker)
      Legate::Verbs::Write.bootstrap(self, legate, @broker)
      Legate::Verbs::Append.bootstrap(self, legate, @broker)
      Legate::Verbs::Mkdir.bootstrap(self, legate, @broker)
      Legate::Verbs::Cp.bootstrap(self, legate, @broker)
      Legate::Verbs::Rm.bootstrap(self, legate, @broker)
      Legate::Verbs::Mv.bootstrap(self, legate, @broker)
      define_global_class(legate)
    end

    # Bootstraps every builtin type's RubyClass into `interp`'s globals,
    # the same namespace `class Foo` writes to — so `5.is_a?(Integer)`
    # and a bare `Integer` reference both resolve. Mirrors
    # Interpreter#bootstrap_error_classes; called once per Interpreter.
    #
    # Builtins.bootstrap_* methods build their own RubyClass directly
    # (RubyClass.new("Integer")) rather than going through
    # define_builtin_class below, since they live in a separate module
    # and only need a name — so the same superclass/rclass defaulting
    # define_builtin_class does has to be patched on here instead,
    # after the fact, rather than being automatic like it is for the
    # error-class hierarchy.
    private def bootstrap_builtin_classes : Nil
      bootstrap_error_classes
      register_builtin_class(Builtins.bootstrap_integer(self))
      register_builtin_class(Builtins.bootstrap_float(self))
      register_builtin_class(Builtins.bootstrap_nil_class(self))
      register_builtin_class(Builtins.bootstrap_true_class(self))
      register_builtin_class(Builtins.bootstrap_false_class(self))
      register_builtin_class(Builtins.bootstrap_symbol(self))
      register_builtin_class(Builtins.bootstrap_string(self))
      register_builtin_class(Builtins.bootstrap_array(self))
      register_builtin_class(Builtins.bootstrap_hash(self))
      register_builtin_class(Builtins.bootstrap_range(self))
      register_builtin_class(Builtins.bootstrap_regexp(self))
      register_builtin_class(Builtins.bootstrap_match_data(self))
      register_builtin_class(Builtins.bootstrap_proc(self))
      register_builtin_class(Builtins.bootstrap_time(self))
      Builtins.register_module_methods(module_class, self)
    end

    # Applies the same superclass/rclass defaulting define_builtin_class
    # does, to a RubyClass that was built OUTSIDE that method (see
    # bootstrap_builtin_classes above) — then registers it into
    # globals. cls.superclass is only defaulted if unset, so a builtin
    # that already set up its own real ancestor (none do yet, but
    # Float subclassing Numeric later might) isn't silently overridden.
    private def register_builtin_class(cls : RubyClass) : RubyClass
      cls.superclass ||= object_class
      cls.rclass = class_class
      define_global_class(cls)
    end

    # `superclass` defaults to Object when not given — the same
    # default a script-written `class Foo; end` gets (see
    # Op::MakeClass). `rclass` is always Class, never overridable here
    # — there's no such thing as a builtin whose class isn't Class,
    # short of the three core classes themselves, which bypass this
    # method entirely (see bootstrap_core_hierarchy).
    private def define_builtin_class(name : String, superclass : RubyClass? = nil) : RubyClass
      cls = RubyClass.new(name, superclass || object_class, is_module: false)
      cls.rclass = class_class
      define_global_class(cls)
    end

    @globals : Hash(Int32, Value) = {} of Int32 => Value
  end
end
