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
    getter cvars : Hash(Int32, Value)
    getter constants : Hash(Int32, Value)
    getter? is_module : Bool

    # The class/module this one was lexically nested inside at the point
    # it was defined (e.g. `class A; class B; end; end` → B.lexical_parent
    # == A). Distinct from `superclass` — this tracks source nesting, not
    # inheritance, and is what constant lookup walks.
    property lexical_parent : RubyClass?

    def initialize(@name : String, @superclass : RubyClass? = nil, @is_module : Bool = false)
      @methods = {} of Int32 => ScriptProc
      @cvars = {} of Int32 => Value
      @constants = {} of Int32 => Value
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

    # Class variables are shared across the hierarchy: a read walks up to
    # the nearest ancestor that has the variable.
    def get_cvar(sym_id : Int32) : Value?
      cls = self
      while cls
        if v = cls.cvars[sym_id]?
          return v
        end
        cls = cls.superclass
      end
      nil
    end

    # A write goes to the nearest ancestor that already defines the
    # variable (matching Ruby's shared-cvar semantics); if no ancestor
    # defines it yet, it's created on this class.
    def set_cvar(sym_id : Int32, val : Value) : Nil
      cls = self
      while cls
        if cls.cvars.has_key?(sym_id)
          cls.cvars[sym_id] = val
          return
        end
        cls = cls.superclass
      end
      @cvars[sym_id] = val
    end

    # Constant lookup walks lexical nesting (source structure), not the
    # superclass chain — distinct from method/cvar resolution.
    def find_constant(sym_id : Int32) : Value?
      cls = self
      while cls
        if v = cls.constants[sym_id]?
          return v
        end
        cls = cls.lexical_parent
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
