module Adjutant
  # A native function callable from scripts.
  # Receives the call arguments and returns a Value.
  alias NativeFunc = ::Proc(Array(Value), ScriptProc?, NativeCallContext, Value)

  # Abstract base for a loadable script module.
  #
  # A ScriptModule is the unit of capability exposure in Adjutant.
  # Scripts access external capabilities exclusively via `require` —
  # each require path maps to a registered ScriptModule.
  #
  # When a script calls `require "agent/io"`, the registry finds the
  # corresponding ScriptModule and calls `load`, which installs whatever
  # globals, constants, and native functions the module provides into
  # the interpreter's namespace.
  #
  # This makes the registry the auditable capability manifest: before
  # executing a script, you can enumerate which modules it requires and
  # surface that to the user.
  #
  # For IFC, modules are the natural label sources — when `agent/http`
  # returns a response body, the module's native code attaches a
  # `{source: :network}` label to the value.
  abstract class ScriptModule
    # The require path this module handles, e.g. "agent/io".
    abstract def name : String

    # Called once when a script requires this module.
    # Install globals, native functions, and constants into interp.
    abstract def load(interp : Interpreter) : Nil
  end

  # Registry of ScriptModules, keyed by require path.
  #
  # Owned by the Interpreter — shared across all script executions
  # within the same interpreter instance.
  class ModuleRegistry
    def initialize
      @modules = {} of String => ScriptModule
      @loaded = Set(String).new
    end

    # Register a module. Replaces any existing module at the same path.
    def register(mod : ScriptModule) : Nil
      @modules[mod.name] = mod
    end

    # Register a simple module from a block without subclassing.
    def register(name : String, &block : Interpreter -> Nil) : Nil
      register(InlineModule.new(name, block))
    end

    # Require a module by path. Returns true if found, false if unknown.
    # Each module is loaded at most once per interpreter instance.
    def require(path : String, interp : Interpreter) : Bool
      mod = @modules[path]?
      return false unless mod
      unless @loaded.includes?(path)
        @loaded.add(path)
        mod.load(interp)
      end
      true
    end

    # True if a module is registered for the given path.
    def registered?(path : String) : Bool
      @modules.has_key?(path)
    end

    # True if a module has already been loaded.
    def loaded?(path : String) : Bool
      @loaded.includes?(path)
    end

    # List all registered module paths — useful for auditing.
    def registered_paths : Array(String)
      @modules.keys
    end

    # List all paths that have been loaded in this session.
    def loaded_paths : Array(String)
      @loaded.to_a
    end

    # A ScriptModule defined inline via a block.
    private class InlineModule < ScriptModule
      def initialize(@name : String, @block : ::Proc(Interpreter, Nil))
      end

      def name : String
        @name
      end

      def load(interp : Interpreter) : Nil
        @block.call(interp)
      end
    end
  end
end
