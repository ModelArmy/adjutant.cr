require "./native_callable"

module Adjutant
  # A class or module, builtin or script-defined. Method tables are
  # keyed by interned symbol id. A module has no superclass and cannot
  # be instantiated.
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

    # True only for the bootstrap `Class` and `Module` classes, which
    # a script cannot instantiate (U002). `VM#construct` checks it.
    getter? uninstantiable : Bool

    # The class of this class: `Integer.rclass` is `Class`, and so is
    # `Class.rclass`. Nil only while the core hierarchy is being
    # bootstrapped.
    property rclass : RubyClass?

    # The class or module this one was defined inside:
    # `class A; class B; end; end` gives B a lexical parent of A.
    # Constant lookup walks this, not the superclass chain.
    property lexical_parent : RubyClass?

    # Modules added by `include`, in source order. Lookup walks them
    # in reverse, so the last one included is checked first.
    getter included_modules : Array(RubyClass)

    # Modules added by `extend`, in source order. Their instance
    # methods become this class's singleton methods.
    getter extended_modules : Array(RubyClass)

    # Symbol ids of this class's own methods that are private: a
    # top-level `def`, as in Ruby, and native methods registered with
    # `is_private`. Scripts cannot declare visibility (U008).
    getter private_methods : Set(Int32)
    getter native_private_methods : Set(Int32)

    def initialize(@name : String, @superclass : RubyClass? = nil, @is_module : Bool = false, @uninstantiable : Bool = false)
      @methods = {} of Int32 => ScriptProc
      @native_methods = {} of Int32 => NativeCallable
      @native_singleton_methods = {} of Int32 => NativeCallable
      @singleton_methods = {} of Int32 => ScriptProc
      @cvars = {} of Int32 => Value
      @ivars = {} of Int32 => Value
      @constants = {} of Int32 => Value
      @included_modules = [] of RubyClass
      @extended_modules = [] of RubyClass
      @private_methods = Set(Int32).new
      @native_private_methods = Set(Int32).new
    end

    # Appends `mod` to the modules this class includes.
    def include_module(mod : RubyClass) : Nil
      @included_modules << mod
    end

    # Appends `mod` to the modules this class extends.
    def extend_module(mod : RubyClass) : Nil
      @extended_modules << mod
    end

    # Defines an instance method. A redefinition is public unless it
    # passes `is_private` again, as in Ruby.
    def define_method(sym_id : Int32, proc : ScriptProc, is_private : Bool = false) : Nil
      @methods[sym_id] = proc
      if is_private
        @private_methods << sym_id
      else
        @private_methods.delete(sym_id)
      end
    end

    # Defines a singleton method (`def self.foo`), which instances do
    # not see.
    def define_singleton_method(sym_id : Int32, proc : ScriptProc) : Nil
      @singleton_methods[sym_id] = proc
    end

    # Finds a singleton method: this class's own, then its extended
    # modules', then the same at each superclass.
    def find_singleton_method(sym_id : Int32) : ScriptProc?
      cls = self
      while cls
        if m = cls.find_own_or_extended_method(sym_id)
          return m
        end
        cls = cls.superclass
      end
      nil
    end

    # Defines a native instance method. The receiver arrives as
    # `args.first`. `risk` has no default, so each registration
    # decides it; see `NativeCallable` for `kwarg_names` and
    # `authorities`.
    def define_native_method(sym_id : Int32, risk : RiskProfile, kwarg_names : Set(String) = Set(String).new, is_private : Bool = false,
                             authorities : Set(Authority) = Set(Authority).new,
                             &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      func = NativeFunc.new { |args, blk, ncc| block.call(args, blk, ncc) }
      @native_methods[sym_id] = NativeCallable.new(func, risk, kwarg_names, authorities)
      if is_private
        @native_private_methods << sym_id
      else
        @native_private_methods.delete(sym_id)
      end
    end

    # Defines a native singleton method: a Legate verb, or a native
    # `new` that allocates a `RubyObject` subclass. The class itself
    # arrives as `args.first`, followed by the call's arguments; a
    # native `new` must return a `Value.robject`. `risk` has no
    # default, as for `define_native_method`.
    def define_native_singleton_method(sym_id : Int32, risk : RiskProfile, kwarg_names : Set(String) = Set(String).new,
                                       authorities : Set(Authority) = Set(Authority).new,
                                       &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      func = NativeFunc.new { |args, blk, ncc| block.call(args, blk, ncc) }
      @native_singleton_methods[sym_id] = NativeCallable.new(func, risk, kwarg_names, authorities)
    end

    # Finds a native singleton method: this class's own, then its
    # extended modules', then the same at each superclass.
    def find_native_singleton_method(sym_id : Int32) : NativeCallable?
      cls = self
      while cls
        if m = cls.find_own_or_extended_native_method(sym_id)
          return m
        end
        cls = cls.superclass
      end
      nil
    end

    # Ruby's `Module#ancestors`: this class, each included module's
    # ancestors (last included first), then the superclass's
    # ancestors. A module reachable twice appears twice. `super`
    # searches this list from the current method's position onward.
    def ancestors : Array(RubyClass)
      result = [self] of RubyClass
      @included_modules.reverse_each { |mod| result.concat(mod.ancestors) }
      if sup = @superclass
        result.concat(sup.ancestors)
      end
      result
    end

    # The singleton-side `ancestors`, for `super` in a class method.
    # Each entry pairs a class or module with the table to search:
    # `true` for singleton methods (this class and its superclasses),
    # `false` for instance methods (the ancestors of each extended
    # module, whose instance methods act as singleton methods here).
    def singleton_ancestors : Array({RubyClass, Bool})
      result = [{self, true}] of {RubyClass, Bool}
      @extended_modules.reverse_each do |mod|
        mod.ancestors.each { |ancestor| result << {ancestor, false} }
      end
      if sup = @superclass
        result.concat(sup.singleton_ancestors)
      end
      result
    end

    # Finds an instance method: this class's own, then its included
    # modules', then the same at each superclass.
    def find_method(sym_id : Int32) : ScriptProc?
      cls = self
      while cls
        if m = cls.find_own_or_included_method(sym_id)
          return m
        end
        cls = cls.superclass
      end
      nil
    end

    # `find_method` for native methods.
    def find_native_method(sym_id : Int32) : NativeCallable?
      cls = self
      while cls
        if m = cls.find_own_or_included_native_method(sym_id)
          return m
        end
        cls = cls.superclass
      end
      nil
    end

    # Whether the method `find_method` returns for `sym_id` is private.
    # Only the definition that wins lookup counts: a public
    # redefinition nearer the receiver overrides a private one
    # further up.
    def find_method_private?(sym_id : Int32) : Bool
      cls = self
      while cls
        result = cls.find_own_or_included_method_private?(sym_id)
        return result unless result.nil?
        cls = cls.superclass
      end
      false
    end

    # `find_method_private?` for native methods.
    def find_native_method_private?(sym_id : Int32) : Bool
      cls = self
      while cls
        result = cls.find_own_or_included_native_method_private?(sym_id)
        return result unless result.nil?
        cls = cls.superclass
      end
      false
    end

    # Searches this class's own methods, then its included modules
    # (last included first, recursing into their own includes). The
    # superclass is left to the caller's loop.
    protected def find_own_or_included_method(sym_id : Int32) : ScriptProc?
      if m = @methods[sym_id]?
        return m
      end
      @included_modules.reverse_each do |mod|
        if m = mod.find_own_or_included_method(sym_id)
          return m
        end
      end
      nil
    end

    # Nil when `sym_id` isn't defined at this level (own table and
    # included modules); otherwise whether that definition is
    # private.
    protected def find_own_or_included_method_private?(sym_id : Int32) : Bool?
      return @private_methods.includes?(sym_id) if @methods.has_key?(sym_id)
      @included_modules.reverse_each do |mod|
        result = mod.find_own_or_included_method_private?(sym_id)
        return result unless result.nil?
      end
      nil
    end

    # `find_own_or_included_method` for native methods.
    protected def find_own_or_included_native_method(sym_id : Int32) : NativeCallable?
      if m = @native_methods[sym_id]?
        return m
      end
      @included_modules.reverse_each do |mod|
        if m = mod.find_own_or_included_native_method(sym_id)
          return m
        end
      end
      nil
    end

    # `find_own_or_included_method_private?` for native methods.
    protected def find_own_or_included_native_method_private?(sym_id : Int32) : Bool?
      return @native_private_methods.includes?(sym_id) if @native_methods.has_key?(sym_id)
      @included_modules.reverse_each do |mod|
        result = mod.find_own_or_included_native_method_private?(sym_id)
        return result unless result.nil?
      end
      nil
    end

    # Searches this class's own singleton methods, then the instance
    # methods of its extended modules (last extended first, including
    # what those modules include). The superclass is left to the
    # caller's loop.
    protected def find_own_or_extended_method(sym_id : Int32) : ScriptProc?
      if m = @singleton_methods[sym_id]?
        return m
      end
      @extended_modules.reverse_each do |mod|
        if m = mod.find_own_or_included_method(sym_id)
          return m
        end
      end
      nil
    end

    # `find_own_or_extended_method` for native methods.
    protected def find_own_or_extended_native_method(sym_id : Int32) : NativeCallable?
      if m = @native_singleton_methods[sym_id]?
        return m
      end
      @extended_modules.reverse_each do |mod|
        if m = mod.find_own_or_included_native_method(sym_id)
          return m
        end
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

    # Class-level ivars (`@x` in a class body or `def self.foo`).
    # Separate from `@@x` cvars even under the same name, and not
    # inherited.
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

    # The qualified name: `A::B` for a class defined inside `A`.
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

  # An instance of a RubyClass, with ivars keyed by symbol id.
  #
  # A native builtin with internal state subclasses this, allocates
  # it from a native singleton `new`, and calls `super(rclass)`.
  class RubyObject
    getter rclass : RubyClass
    getter ivars : Hash(Int32, Value)

    # For a Proc, the closure captured where its `->(){}` or
    # `lambda { }` was evaluated; nil for any other object. Not an
    # ivar, since scripts must not read or assign it.
    property outer_locals : OuterChain?

    def initialize(@rclass : RubyClass)
      @ivars = {} of Int32 => Value
    end

    # Whether this object's class or one of its superclasses is named
    # `class_name`. Included modules are not checked.
    def instance_of?(class_name : String)
      superclass = rclass
      while superclass && superclass.name != class_name
        superclass = superclass.superclass
      end
      !superclass.nil?
    end

    def to_s(io : IO) : Nil
      io << "#<" << @rclass.name << ">"
    end
  end
end
