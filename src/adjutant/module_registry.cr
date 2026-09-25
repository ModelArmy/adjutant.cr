module Adjutant
  # A native function: called with the arguments, the block if any,
  # and a NativeCallContext; returns a Value.
  alias NativeFunc = ::Proc(Array(Value), ScriptProc?, NativeCallContext, Value)

  # A module a script loads with `require`, which installs its
  # globals, constants and native functions. The registry is the
  # manifest of what a script can load. A module's native code labels
  # the data it returns, as Legate's verbs do.
  abstract class ScriptModule
    # The require path this module handles, e.g. "agent/io".
    abstract def name : String

    # Installs the module's globals, functions and constants. Called
    # once, on first `require`.
    abstract def load(interp : Interpreter) : Nil
  end

  # ScriptModules by require path, shared by every run on the
  # Interpreter that owns it.
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

    # Every path loaded so far by this Interpreter.
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
