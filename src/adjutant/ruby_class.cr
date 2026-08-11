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

    # True only for the two bootstrap RubyClasses representing Class and
    # Module themselves (see Interpreter#bootstrap_core_hierarchy) —
    # NOT for an ordinary `module Foo; end` (that's `is_module?`,
    # already blocked from `.new` on its own terms). `Class`/`Module`
    # exist purely so `.class`/`is_a?`/`superclass` resolve correctly
    # for every other RubyClass; they were never meant to be
    # instantiable from script (see UNSUPPORTED.md's U002,
    # `Class.new`/`Module.new`). Checked by `VM#construct`.
    getter? uninstantiable : Bool

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

    # Modules mixed in via `include`, in INSERTION order (index 0 =
    # first included). `find_method`/`find_native_method` (below)
    # walk this in REVERSE — real Ruby's MRO: the LAST module
    # included sits CLOSEST to the class, so it's checked FIRST,
    # ahead of earlier includes and ahead of the superclass. Empty for
    # the overwhelming majority of classes/modules (no `include` in
    # their body at all) — a plain `Array(RubyClass)`, not nilable,
    # since checking `.empty?` costs nothing and every RubyClass
    # already allocates several other always-present collections the
    # same way (`methods`, `ivars`, ...).
    getter included_modules : Array(RubyClass)

    # Modules mixed in via `extend`, same shape as `included_modules`
    # above but for the SINGLETON chain — `extend M` makes M's methods
    # available as CLASS methods (callable on the class/module object
    # itself), not instance methods. Genuinely separate storage from
    # `included_modules`, not a reused field: the two lists mean
    # different things (instance resolution vs. singleton resolution)
    # — an `include`d module showing up in singleton resolution, or
    # vice versa, would be a real correctness bug, not a harmless
    # simplification. See `find_singleton_method`/
    # `find_native_singleton_method`, below, for the read side.
    getter extended_modules : Array(RubyClass)

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
    end

    # `include SomeModule` — mixes SomeModule's instance methods into
    # this class/module's own resolution chain (see
    # `find_method`/`find_native_method`, below). Appending, not
    # prepending: insertion order is preserved here; it's the READ
    # side (the two `find_*` methods) that walks the array in reverse
    # to get real Ruby's "last included wins" MRO — keeping storage
    # order the same as source order, rather than storing it
    # pre-reversed, is easier to reason about from a debugger and
    # matches how `methods`/`native_methods` etc. are populated
    # (whatever order `define`/`define_method` were actually called
    # in, no reordering).
    def include_module(mod : RubyClass) : Nil
      @included_modules << mod
    end

    # `extend SomeModule` — same shape as `include_module` above, but
    # into `extended_modules`. See that field's own comment for why
    # this is genuinely separate storage, not a reused list.
    def extend_module(mod : RubyClass) : Nil
      @extended_modules << mod
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
    #
    # `kwarg_names` declares which keyword names this method accepts
    # (see NativeCallable#kwarg_names) — empty by default, matching
    # every pre-existing native method, which accepted none.
    def define_native_method(sym_id : Int32, risk : RiskProfile, kwarg_names : Set(String) = Set(String).new,
                             &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      func = NativeFunc.new { |args, blk, ncc| block.call(args, blk, ncc) }
      @native_methods[sym_id] = NativeCallable.new(func, risk, kwarg_names)
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
    #
    # `kwarg_names` — see define_native_method's own note; lets a
    # native `new` (e.g. `Config.new(retries:, timeout:)`) declare
    # accepted keyword names the same way.
    def define_native_singleton_method(sym_id : Int32, risk : RiskProfile, kwarg_names : Set(String) = Set(String).new,
                                       &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      func = NativeFunc.new { |args, blk, ncc| block.call(args, blk, ncc) }
      @native_singleton_methods[sym_id] = NativeCallable.new(func, risk, kwarg_names)
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

    # The full linearized method-resolution order (real Ruby's
    # `Module#ancestors`) — this class/module itself, then its own
    # included modules (reverse order — real MRO: the LAST module
    # `include`d sits CLOSEST, so it's listed first among them, same
    # reasoning as `find_own_or_included_method`'s own comment — each
    # expanded RECURSIVELY via its own `ancestors`, since a module can
    # itself `include` another module), then — if this is a class,
    # not a module — the superclass's own full `ancestors`. A
    # module's own `superclass` is always nil, so this naturally
    # terminates there with no special-casing needed for the
    # class-vs-module distinction; the SAME method works for both.
    #
    # Needed by `VM#dispatch_super` (STEP 4 of the include-support
    # build-out — see SCOPE.md's git history): `super`'s resolution
    # can't just jump from the currently-executing method's own class
    # to that class's `superclass` anymore once modules exist in the
    # picture — a module `include`d directly into that class sits
    # BETWEEN it and its superclass in the real MRO, and if `super`
    # is called from INSIDE a module's own method, that module has no
    # `superclass` of its own to fall back on at all (only the ACTUAL
    # receiver's full ancestry knows what comes next). `dispatch_super`
    # computes this once per call, finds where the current method's
    # own `lexical_scope` sits in it, and searches everything AFTER
    # that position — see that method's own comment for the full
    # reasoning.
    #
    # No de-duplication — matches `RubyClass#include_module`'s own
    # currently-open question (see that method's comment): a module
    # included twice, or reachable via two different paths, appears
    # more than once here. Not a correctness problem for `super`'s
    # own search (the right answer is still found, just possibly
    # checked against the same module redundantly) — worth revisiting
    # together with `include_module`'s own de-dup question if either
    # is ever addressed.
    def ancestors : Array(RubyClass)
      result = [self] of RubyClass
      @included_modules.reverse_each { |mod| result.concat(mod.ancestors) }
      if sup = @superclass
        result.concat(sup.ancestors)
      end
      result
    end

    # Look up a method by symbol id: this class/module's OWN methods
    # first, then its included modules (STEP 3 of the include-support
    # build-out — see SCOPE.md's git history; the module was already
    # being recorded since Step 2, but nothing consulted it until
    # this), then repeat at the superclass, and so on up the chain.
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

    # Look up a native method by symbol id — same shape as
    # find_method, separate table.
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

    # Checks THIS class/module's own method table, then its included
    # modules — deliberately NOT the superclass (find_method's own
    # loop, above, handles moving up that chain; folding it in here
    # too would search each ancestor's own modules once per level
    # AND once again via the outer loop's next iteration reaching the
    # same class). `included_modules.reverse_each`: real Ruby's MRO —
    # the LAST module `include`d sits CLOSEST to the class, so it's
    # checked FIRST, ahead of earlier includes (RubyClass#
    # include_module's own comment has the storage-order reasoning).
    # Recurses into each module's OWN find_own_or_included_method,
    # not just a flat one-level check — a module can itself `include`
    # another module, and real Ruby's MRO flattens that nesting into
    # the search too, not just the class's own direct includes.
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

    # Same shape as find_own_or_included_method, native table.
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
    property outer_locals : OuterChain?

    def initialize(@rclass : RubyClass)
      @ivars = {} of Int32 => Value
    end

    # Return true if `class_name` matches one of this object's class chain.
    # Checks superclass chain only. Included modules not yet supported
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
