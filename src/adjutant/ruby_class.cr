require "./native_callable"

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
    getter native_methods : Hash(Int32, NativeCallable)
    getter native_singleton_methods : Hash(Int32, NativeCallable)
    getter singleton_methods : Hash(Int32, ScriptProc)
    getter cvars : Hash(Int32, Value)
    getter ivars : Hash(Int32, Value)
    getter constants : Hash(Int32, Value)
    getter? is_module : Bool

    # The class OF this class — `Integer.rclass == Class`,
    # `Class.rclass == Class` (the one genuinely self-referential case
    # in the hierarchy). Nilable only to break the bootstrap
    # chicken-and-egg: `Class` itself can't have a valid `rclass` at
    # the moment it's allocated, since nothing exists yet to point to.
    # See Interpreter#bootstrap_core_hierarchy — every RubyClass other
    # than the three core ones is expected to have this set by the time
    # a script can observe it (`.class` on a `nil` rclass is a bug, not
    # a valid state to display to a script).
    property rclass : RubyClass?

    # The class/module this one was lexically nested inside at the point
    # it was defined (e.g. `class A; class B; end; end` → B.lexical_parent
    # == A). Distinct from `superclass` — this tracks source nesting, not
    # inheritance, and is what constant lookup walks.
    property lexical_parent : RubyClass?

    def initialize(@name : String, @superclass : RubyClass? = nil, @is_module : Bool = false)
      @methods = {} of Int32 => ScriptProc
      @native_methods = {} of Int32 => NativeCallable
      @native_singleton_methods = {} of Int32 => NativeCallable
      @singleton_methods = {} of Int32 => ScriptProc
      @cvars = {} of Int32 => Value
      @ivars = {} of Int32 => Value
      @constants = {} of Int32 => Value
    end

    def define_method(sym_id : Int32, proc : ScriptProc) : Nil
      @methods[sym_id] = proc
    end

    # Register a script-defined singleton (class-level) method —
    # `def self.foo` inside a class body. Separate table from
    # `methods`, mirroring the native_methods/native_singleton_methods
    # split: an instance never sees these, and a singleton call never
    # sees `methods`.
    def define_singleton_method(sym_id : Int32, proc : ScriptProc) : Nil
      @singleton_methods[sym_id] = proc
    end

    # Look up a script-defined singleton method by symbol id, walking
    # the superclass chain — same shape as find_method, separate
    # table.
    def find_singleton_method(sym_id : Int32) : ScriptProc?
      cls = self
      while cls
        if m = cls.singleton_methods[sym_id]?
          return m
        end
        cls = cls.superclass
      end
      nil
    end

    # Register a Crystal-implemented instance method under this class.
    #
    # `risk` has no default — unlike Interpreter#define_native. Base
    # types are registered in bulk in one place, which is exactly where
    # it's easiest to wave a whole batch through as RiskProfile.none
    # without thinking about it; making the parameter mandatory here
    # forces that judgment call at each method.
    #
    # The receiver is passed as `args.first`, matching the calling
    # convention VM#exec_builtin already uses for receiver methods
    # (`to_s`, `length`, `is_a?`, etc.) — native methods have no
    # separate `self` binding the way ScriptProc methods do via Frame.
    def define_native_method(sym_id : Int32, risk : RiskProfile,
                             &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      func = NativeFunc.new { |args, blk, ncc| block.call(args, blk, ncc) }
      @native_methods[sym_id] = NativeCallable.new(func, risk)
    end

    # Register a Crystal-implemented singleton (class-level) method
    # under this class — currently the only route in is `new`, for a
    # builtin that needs to allocate a RubyObject subclass with real
    # native state instead of the generic construct_object path (e.g.
    # File.new opening a handle). Not a general `def self.foo`
    # mechanism for script-defined classes — that stays unscoped, see
    # DEVELOPMENT.md.
    #
    # `risk` has no default for the same reason as
    # define_native_method: forces a judgment call at each
    # registration rather than a batch rubber-stamp.
    #
    # Unlike an instance native method, the singleton method receives
    # the RubyClass itself as args.first (not a receiver instance —
    # there isn't one yet, that's the point of `new`), followed by the
    # constructor arguments. It is responsible for its own allocation
    # and must return a Value.robject.
    def define_native_singleton_method(sym_id : Int32, risk : RiskProfile,
                                       &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      func = NativeFunc.new { |args, blk, ncc| block.call(args, blk, ncc) }
      @native_singleton_methods[sym_id] = NativeCallable.new(func, risk)
    end

    # Look up a native singleton method by symbol id, walking the
    # superclass chain — same shape as find_native_method, separate
    # table. A subclass with no native `new` of its own inherits its
    # ancestor's (e.g. a File subclass reusing File.new).
    def find_native_singleton_method(sym_id : Int32) : NativeCallable?
      cls = self
      while cls
        if m = cls.native_singleton_methods[sym_id]?
          return m
        end
        cls = cls.superclass
      end
      nil
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

    # Look up a native method by symbol id, walking the superclass
    # chain — same shape as find_method, separate table.
    def find_native_method(sym_id : Int32) : NativeCallable?
      cls = self
      while cls
        if m = cls.native_methods[sym_id]?
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

    # Class ivars (`@x` read/written directly in a class body or a
    # `def self.foo` singleton method) live in their OWN slot, entirely
    # separate from cvars (`@@x`) even when the name collides — this is
    # real Ruby semantics, not a simplification: `A.x` and `A.new.x` can
    # both be named `@x` and still hold independent values. Unlike
    # cvars, class ivars are NOT inherited — no superclass walk, same
    # as an instance's own ivars never leak to other instances.
    def get_ivar(sym_id : Int32) : Value?
      @ivars[sym_id]?
    end

    def set_ivar(sym_id : Int32, val : Value) : Nil
      @ivars[sym_id] = val
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

    # Fully-qualified name, walking lexical_parent — `class A; class
    # B; end; end` gives B.to_s == "A::B", matching real Ruby. A
    # top-level class/module (lexical_parent nil) is just its own
    # name.
    def to_s(io : IO) : Nil
      io << qualified_name
    end

    def qualified_name : String
      if parent = @lexical_parent
        "#{parent.qualified_name}::#{@name}"
      else
        @name
      end
    end
  end

  # An instance of a RubyClass.
  #
  # Ivars are keyed by interned symbol id, mirroring RubyClass's
  # method table and the existing GetIvar/SetIvar opcode contract.
  #
  # `rclass` here and RubyClass#rclass are the same relationship
  # ("what class is THIS thing an instance of") at two different
  # levels — an instance's rclass is the class that built it; a
  # class's own rclass is (almost always) Class itself. They share a
  # name deliberately, matching how `obj.class` and `SomeClass.class`
  # are genuinely the same method in real Ruby — not a coincidence to
  # be confused by.
  #
  # Open to subclassing: a native builtin with real internal state
  # (e.g. an open file handle) defines a RubyObject subclass with its
  # own typed ivars, allocated by a native singleton `new` method
  # instead of the generic `construct_object` path — see
  # RubyClass#native_singleton_methods. A subclass calls `super(rclass)`
  # from its own initializer to set up the base rclass/ivars.
  class RubyObject
    getter rclass : RubyClass
    getter ivars : Hash(Int32, Value)

    # Closure snapshot for a Proc instance only — the enclosing
    # frame's locals at the moment a `->(){}` literal was evaluated
    # (see VM#make_lambda_object, Op::MakeProc's a=1 branch). Nil for
    # every RubyObject that isn't a Proc.
    #
    # Not stored in `ivars` because that Hash is script-visible
    # instance state and can only hold real `Value`s — there's no
    # `Value` variant for a raw `Array(Value)` of VM locals, and there
    # shouldn't be one; this is VM-internal plumbing a script can
    # never read or assign, exactly like Frame#outer_locals itself
    # (also a plain, non-Value-wrapped field). A Proc-specific
    # RubyObject subclass was considered and rejected: nothing else
    # can construct a RubyObject whose rclass is Proc, so there's no
    # ambiguity a subtype would guard against — this field is simply
    # unused (nil) for every other class, the same way `ivars` itself
    # holds different keys depending on which class populated it.
    property outer_locals : Array(Value)?

    def initialize(@rclass : RubyClass)
      @ivars = {} of Int32 => Value
    end

    def to_s(io : IO) : Nil
      io << "#<" << @rclass.name << ">"
    end
  end
end
