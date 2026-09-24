require "./risk_profile"
require "./risk_flow_label"
require "./native_callable"
require "./vm"

module Adjutant
  # The VM services a native function can use through its `ncc`
  # argument: calling blocks, Procs and methods, comparing and adding
  # Values with script semantics, and raising script-catchable errors.
  module NativeCallContext
    getter filename : String
    getter line : Int32

    # The call's keyword arguments, or nil when it passed none. Only
    # names declared in the function's `kwarg_names` reach here; a
    # function supplies its own default for an omitted key:
    # `ncc.kwargs.try(&.["timeout"]?) || default`.
    getter kwargs : Hash(String, Value)?

    # `self` at the call site. Explicit-receiver calls get their
    # receiver as `args.first`; this is for calls made with an
    # implicit receiver, such as `include Foo` in a class body, whose
    # `args` carry no receiver.
    abstract def self_val : Value

    # Runs a block passed at the call site (`{ }` or `do...end`), the
    # `blk` a native function receives. For a stored `Proc` value, use
    # `invoke_proc`: this method runs the block against the current
    # frame, which is only its defining frame while the call is live.
    abstract def invoke(proc : ScriptProc, args : Array(Value)) : Value

    # Calls a stored `Proc` object (from `->(){}` or `lambda { }`)
    # with its own captured closure.
    abstract def invoke_proc(proc_obj : RubyObject, args : Array(Value)) : Value

    # Returns a live call-site block as a `Proc` object, closing over
    # the frame that made this call. `lambda { }` is built with it.
    abstract def wrap_block_as_proc(blk : ScriptProc) : Value

    # Ruby's `==`: structural for Array and Hash, identity for
    # RubyObject, value equality for scalars. Same logic as `Op::Eq`.
    abstract def values_equal?(a : Value, b : Value) : Bool

    # Ruby's `<`, `<=`, `>` or `>=` (`op` is `:<`, `:<=`, `:>` or
    # `:>=`), as `ValueOps.compare` computes it for script code.
    # False for a pair with no order.
    abstract def compare(a : Value, b : Value, op : Symbol) : Bool

    # Ruby's `<=>`: a negative, zero or positive Int32, or nil when `a`
    # and `b` have no order. Arrays compare element by element; a
    # RubyObject uses its own `<=>`. For native methods that sort.
    abstract def spaceship(a : Value, b : Value) : Int32?

    # `spaceship`, but raises R044 (`ArgumentError`) instead of
    # returning nil. For native methods that must order every pair.
    abstract def order(a : Value, b : Value) : Int32

    # Ruby's `+`, as `Op::Add` computes it. `call_method(a, "+", ...)`
    # cannot do this: `+` on builtin types is an opcode, not a
    # registered method.
    abstract def add(a : Value, b : Value) : Value

    # Calls `recv.name(*args)` through normal dispatch: script-defined
    # methods first, then native ones.
    abstract def call_method(recv : Value, name : String, args : Array(Value)) : Value

    # Runs the block to render the container `obj_id`, unless that
    # container is already being rendered further up the stack, in
    # which case it returns `cycle_result` (`"[...]"` for Array)
    # without running the block. `obj_id` is the container's Crystal
    # `object_id`. For any `inspect` that recurses into its elements,
    # so `a = []; a << a; a.inspect` gives `[[...]]`.
    abstract def guard_rendering(obj_id : UInt64, cycle_result : String, & : -> String) : String

    # Declares that the subject `origin` of kind `kind` (a path, a
    # URL) is what this call exercises `authority` on, and runs the
    # same risk-flow check a labelled argument triggers. Call it on
    # the argument that is itself the risky subject; a literal
    # carries no label for the automatic check to see. Pass
    # `sensitivity` to skip the policy lookup.
    #
    # Returns the subject's label, or nil if policy doesn't consider
    # it sensitive. Tag the data the call returns with it.
    abstract def declare_sensitivity(authority : Authority, kind : ProvenanceKind, origin : String,
                                     sensitivity : Sensitivity? = nil) : RiskFlowLabel?

    # Raises the catalog diagnostic `code`, filled with `data`, as a
    # script-catchable `error_class`. Use it to reject bad input the
    # way Ruby would (`Integer#to_s(37)` raises `ArgumentError`).
    abstract def raise_error(code : String, data : Hash(String, String) = {} of String => String,
                             error_class : String = "RuntimeError") : NoReturn

    # Raises `error_class` with a computed `message`, for classes that
    # `raise_error` cannot name, such as the nested `Legate::Malformed`.
    # Each `attributes` entry becomes an ivar (key without `@`) that a
    # script reads through a reader method the class must define;
    # `Legate::Redirect` is the example.
    abstract def raise_error_class(message : String, error_class : RubyClass,
                                   attributes : Hash(String, Value)? = nil) : NoReturn
  end
end
