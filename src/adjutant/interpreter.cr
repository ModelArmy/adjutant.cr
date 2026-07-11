require "./symbol_table"
require "./lexer"
require "./parser"
require "./compiler"
require "./bytecode"
require "./module_registry"
require "./vm"
require "./effect_handler"
require "./risk_profile"
require "./native_callable"
require "./builtins"

module Adjutant
  # Available to native functions when they are called.
  module NativeCallContext
    getter filename : String
    getter line : Int32

    # Use this method to yield / call a block from a native
    # function
    abstract def invoke(proc : ScriptProc, args : Array(Value)) : Value

    # Real Ruby `==` semantics (deep/structural for Array and Hash,
    # identity for RubyObject, value equality for scalars — see
    # VM#values_equal?, the single source of truth this delegates to).
    # Needed by any native method that has to compare Values for
    # equality (Array#include?, Hash key lookup on a container-typed
    # key, ...) — without this, such a method would either be unable
    # to compare correctly at all, or would have to duplicate
    # values_equal?'s logic itself and risk drifting out of sync with
    # what Op::Eq actually does.
    abstract def values_equal?(a : Value, b : Value) : Bool
  end

  struct NativeFunctionCall
    include NativeCallContext

    @vm : VM
    @callable : NativeCallable

    protected def initialize(@vm, @callable, @filename, @line); end

    protected def call(args : Array(Value), blk : ScriptProc?) : Value
      @callable.call(args, blk, self)
    end

    # ---- CallContext
    def invoke(proc : ScriptProc, args : Array(Value)) : Value
      @vm.invoke(proc, args)
    end

    def values_equal?(a : Value, b : Value) : Bool
      @vm.values_equal?(a, b)
    end
  end

  # Top-level entry point for the Adjutant interpreter.
  #
  # Owns the SymbolTable (shared across all compilations), the
  # ModuleRegistry (capability manifest), and creates a fresh VM
  # per execution. The EffectHandler defines the containment boundary
  # for physical effects.
  #
  # Usage:
  #   effect  = TestEffectHandler.new
  #   interp  = Interpreter.new(effect: effect)
  #   interp.modules.register("agent/io") { |i| ... }
  #   interp.eval("require \"agent/io\"\nputs(42)")
  class Interpreter
    getter symbols : SymbolTable
    getter modules : ModuleRegistry
    getter effect : EffectHandler?
    getter limits : ExecutionLimits
    getter flow_log : FlowLog

    def initialize(
      @effect : EffectHandler? = nil,
      @limits : ExecutionLimits = ExecutionLimits.new,
      flow_tracking : Bool = false,
    )
      @symbols = SymbolTable.new
      @modules = ModuleRegistry.new
      @globals = {} of Int32 => Value
      @flow_log = FlowLog.new(enabled: flow_tracking)
      bootstrap_core_hierarchy
      bootstrap_error_classes
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

    # Parse, compile, and execute a source string.
    def eval(source : String, filename : String = "<eval>") : Value
      eval(IO::Memory.new(source), filename)
    end

    # Parse, compile, and execute from an IO stream.
    def eval(io : IO, filename : String = "<eval>") : Value
      body = Parser.new(io, filename).parse
      chunk = Compiler.compile(body, @symbols)
      vm = make_vm
      result = vm.run(chunk, filename)
      result
    end

    # Compile a source string without executing — for pre-validation.
    def compile(source : String, filename : String = "<compile>") : Chunk
      compile(IO::Memory.new(source), filename)
    end

    def compile(io : IO, filename : String = "<compile>") : Chunk
      body = Parser.new(io, filename).parse
      Compiler.compile(body, @symbols)
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

      raise RuntimeError.new("'require' cannot load -- #{path}", filename, 0)
    end

    # Install a native function as a global callable from scripts with arguments array, block if any, and
    # a `NativeCallContext` that can be used to invoke the block.
    #
    # `risk` declares the function's static side-effect profile — see
    # RiskProfile. Defaults to RiskProfile.none (pure, no side effects),
    # correct for the common case; pass an explicit profile for any
    # function with file, network, process, or environment effects.
    def define_native(name : String, risk : RiskProfile = RiskProfile.none,
                      &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      sym = @symbols.intern(name)
      func = NativeFunc.new { |args, blk, ncc| block.call(args, blk, ncc) }
      native_funcs[sym.value] = NativeCallable.new(func, risk)
    end

    # Look up a native callable by symbol ID — called by VM dispatch.
    # Returns both the function and its RiskProfile.
    def native_callable(sym_id : Int32) : NativeCallable?
      @native_funcs[sym_id]?
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

    private def make_vm : VM
      VM.new(@symbols, @limits, @effect, self, @globals, @flow_log)
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
    # see DEVELOPMENT.md's "Forbidden and out-of-scope features". This
    # bootstrap only needs Class/Module to EXIST as real RubyClasses
    # for `.class`/`is_a?`/`ancestors` to work correctly; it does not
    # make them instantiable from script.
    private def bootstrap_core_hierarchy : Nil
      mod_cls = RubyClass.new("Module", nil, is_module: false)
      class_cls = RubyClass.new("Class", nil, is_module: false)
      obj_cls = RubyClass.new("Object", nil, is_module: false)

      class_cls.superclass = mod_cls
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
      exception = define_builtin_class("Exception")
      standard_error = define_builtin_class("StandardError", exception)
      define_builtin_class("RuntimeError", standard_error)
      define_builtin_class("TypeError", standard_error)
      define_builtin_class("ArgumentError", standard_error)
      define_builtin_class("ZeroDivisionError", standard_error)
      name_error = define_builtin_class("NameError", standard_error)
      define_builtin_class("NoMethodError", name_error)
      index_error = define_builtin_class("IndexError", standard_error)
      define_builtin_class("KeyError", index_error)
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
      register_builtin_class(Builtins.bootstrap_integer(self))
      register_builtin_class(Builtins.bootstrap_float(self))
      register_builtin_class(Builtins.bootstrap_nil_class(self))
      register_builtin_class(Builtins.bootstrap_true_class(self))
      register_builtin_class(Builtins.bootstrap_false_class(self))
      register_builtin_class(Builtins.bootstrap_symbol(self))
      register_builtin_class(Builtins.bootstrap_string(self))
      register_builtin_class(Builtins.bootstrap_array(self))
      register_builtin_class(Builtins.bootstrap_hash(self))
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
    @native_funcs = {} of Int32 => NativeCallable

    private def native_funcs : Hash(Int32, NativeCallable)
      @native_funcs
    end
  end
end
