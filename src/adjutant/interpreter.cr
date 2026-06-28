require "./symbol_table"
require "./lexer"
require "./parser"
require "./compiler"
require "./bytecode"
require "./module_registry"
require "./vm"
require "./effect_handler"

module Adjutant
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

      raise RuntimeError.new("cannot load -- #{path}", filename, 0)
    end

    # Install a native function as a global callable from scripts.
    def define_native(name : String, &block : Array(Value) -> Value) : Nil
      sym = @symbols.intern(name)
      native_funcs[sym.value] = NativeFunc.new { |args| block.call(args) }
    end

    # Look up a native function by symbol ID — called by VM dispatch.
    def native_func(sym_id : Int32) : NativeFunc?
      @native_funcs[sym_id]?
    end

    private def make_vm : VM
      VM.new(@symbols, @limits, @effect, self, @globals)
    end

    @globals : Hash(Int32, Value) = {} of Int32 => Value
    @native_funcs = {} of Int32 => NativeFunc

    private def native_funcs : Hash(Int32, NativeFunc)
      @native_funcs
    end
  end
end
