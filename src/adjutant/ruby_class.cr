module Adjutant
  # A user-defined class or module.
  #
  # Holds a method table keyed by interned symbol id (Sym#value) so
  # method lookup is an O(1) hash access, consistent with how globals
  # and ivars are already keyed. `is_module` distinguishes `module`
  # from `class` for future `include` semantics; modules have no
  # superclass and cannot be instantiated.
  class RubyClass
    getter name : String
    property superclass : RubyClass?
    getter methods : Hash(Int32, ScriptProc)
    getter is_module : Bool

    def initialize(@name : String, @superclass : RubyClass? = nil, @is_module : Bool = false)
      @methods = {} of Int32 => ScriptProc
    end

    def define_method(sym_id : Int32, proc : ScriptProc) : Nil
      @methods[sym_id] = proc
    end

    # Look up a method by symbol id, walking the superclass chain.
    def find_method(sym_id : Int32) : ScriptProc?
      cls = self
      while cls
        if m = cls.methods[sym_id]?
          return m
        end
        cls = cls.superclass
      end
      nil
    end

    def to_s(io : IO) : Nil
      io << (@is_module ? "module " : "class ") << @name
    end
  end

  # An instance of a RubyClass.
  #
  # Ivars are keyed by interned symbol id, mirroring RubyClass's
  # method table and the existing GetIvar/SetIvar opcode contract.
  class RubyObject
    getter rclass : RubyClass
    getter ivars : Hash(Int32, Value)

    def initialize(@rclass : RubyClass)
      @ivars = {} of Int32 => Value
    end

    def to_s(io : IO) : Nil
      io << "#<" << @rclass.name << ">"
    end
  end
end
