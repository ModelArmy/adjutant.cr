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

    def initialize(
      @effect : EffectHandler? = nil,
      @limits : ExecutionLimits = ExecutionLimits.new,
    )
      @symbols = SymbolTable.new
      @modules = ModuleRegistry.new
      @globals = {} of Int32 => Value
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
    # (e.g. Integer for an int Value) — used by is_a? and eventually
    # `.class`, since builtin values aren't RubyObjects and so carry no
    # rclass reference of their own to walk. Returns nil for a receiver
    # kind with no builtin RubyClass yet.
    def builtin_class_for(val : Value) : RubyClass?
      name = case
             when val.int? then "Integer"
             else               return nil
             end
      sym = @symbols.lookup(name)
      return nil unless sym
      @globals[sym.value]?.try(&.as_rclass?)
    end

    private def make_vm : VM
      VM.new(@symbols, @limits, @effect, self, @globals)
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
      exception = define_builtin_class("Exception", nil)
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
    private def bootstrap_builtin_classes : Nil
      define_global_class(Builtins.bootstrap_integer(self))
    end

    private def define_builtin_class(name : String, superclass : RubyClass?) : RubyClass
      define_global_class(RubyClass.new(name, superclass, is_module: false))
    end

    @globals : Hash(Int32, Value) = {} of Int32 => Value
    @native_funcs = {} of Int32 => NativeCallable

    private def native_funcs : Hash(Int32, NativeCallable)
      @native_funcs
    end
  end
end
