require "./risk_profile"
require "./risk_flow_label"
require "./native_callable"
require "./vm"

module Adjutant
  module NativeCallContext
    getter filename : String
    getter line : Int32

    # The caller's keyword arguments, if any — nil when the call site
    # passed none at all (same nil-vs-empty-Hash convention `bind_args`
    # and `check_risk_flow` already use elsewhere). Deliberately NOT a
    # parameter on NativeFunc itself (Array(Value), ScriptProc?,
    # NativeCallContext -> Value) — widening that Proc's arity would
    # touch every existing native function definition across the
    # codebase (testing/assert_module.cr, builtins/*.cr) for a
    # capability most of them don't need. Routing kwargs through the
    # context instead means only a native function that actually
    # declares kwarg_names (see NativeCallable) needs to read this;
    # everyone else is unaffected. A native function that wants a
    # default value for an omitted key reads this Hash directly
    # (`ncc.kwargs.try(&.["timeout"]?) || default_value`) — see
    # NativeCallable#kwarg_names's own comment for why no separate
    # default-declaration mechanism exists.
    getter kwargs : Hash(String, Value)?

    # `self` at the call site — needed by a native method that cares
    # WHICH object/class it was called on when it can't rely on
    # `args.first` for that (the explicit-receiver dispatch
    # convention every OTHER native method in `builtins/*.cr` uses).
    # A bare call made from inside a class/module body (`include Foo`,
    # called with implicit self) is the first user: that dispatch
    # path never prepends a receiver into `args` at all — see
    # `VM#current_self_val`'s own comment for the full reasoning.
    # Explicit-receiver calls keep using `args.first` as before; this
    # exists for the OTHER shape, not as a replacement for it.
    abstract def self_val : Value

    # Use this method to yield / call a LIVE call-site block (`{ }`/
    # `do...end`) from a native function — Array#each/Range#each/
    # Hash#each's `blk` param, etc. Never use this for a stored `Proc`
    # value (from a `->(){}` literal) — use `invoke_proc` instead. See
    # VM#invoke's own comment for why the two are split and can't be
    # merged back into one optional-param method safely.
    abstract def invoke(proc : ScriptProc, args : Array(Value)) : Value

    # The only correct way to call a stored `Proc` object (as opposed
    # to a live call-site block — see `invoke` above). Pass the `Proc`
    # RubyObject itself; its real closure snapshot is pulled from it
    # internally, so there's no raw outer_locals array for a caller to
    # forget. See VM#invoke_proc's own comment for the full reasoning.
    abstract def invoke_proc(proc_obj : RubyObject, args : Array(Value)) : Value

    # Wraps a LIVE call-site block (the `blk` a native function's own
    # `define_native`/`define` block receives) into a real `Proc`
    # RubyObject — the same object shape a `->(){}` lambda literal
    # produces (`compile_lambda`/`Op::MakeProc` a=1, vm.cr), so it
    # gets `.call`/`.lambda?`/`.to_s` etc. for free via Proc's own
    # native methods. This is what `lambda { ... }`/`proc { ... }`
    # (builtins/proc.cr) are built from — the closure it captures is
    # this call's OWN creation site (the frame that was running when
    # `lambda`/`proc` itself was called), matching what a `->(){}`
    # literal written at that exact spot would have captured, since a
    # native call pushes no VM frame of its own to get in the way.
    abstract def wrap_block_as_proc(blk : ScriptProc) : Value

    # Real Ruby `==` semantics (deep/structural for Array and Hash,
    # identity for RubyObject, value equality for scalars — see
    # VM#values_equal?, the single source of truth this delegates to).
    # Needed by any native method that has to compare Values for
    # equality (Array#include?, Hash key lookup on a container-typed
    # key, ...) — without this, such a method would either be unable
    # to compare correctly at all, or would have to duplicate
    # values_equal?'s logic itself and risk drifting out of sync with
    # what Op::Eq actually does.
    abstract def values_equal?(a : Value, b : Value) : Bool

    # Real Ruby `<=>`-style ordering for two Values — delegates to
    # ValueOps.compare (value_ops.cr), the same comparison logic
    # Op::Lt/Op::Le/etc. already use for `<`/`<=`/`>`/`>=` in script
    # code. Needed by any native method that has to order Values
    # without duplicating that logic (Range#each's loop condition —
    # see builtins/range.cr — is the first user). `op` is one of :<,
    # :<=, :>, :>=, matching ValueOps.compare's own symbol vocabulary;
    # returns false for any pair it doesn't know how to order
    # (mirroring its own permissive-false fallback rather than
    # raising).
    abstract def compare(a : Value, b : Value, op : Symbol) : Bool

    # Real Ruby `+` semantics for two Values — delegates to
    # ValueOps.add (value_ops.cr), the same logic Op::Add already uses
    # for script-level `+`. Needed by any native method that has to
    # add Values generically without duplicating that logic —
    # Range#step's own advance-by-n (see builtins/range.cr) is the
    # first user, and specifically CAN'T use `call_method(a, "+",
    # [b])` for this the way #each uses `call_method(a, "succ", [])`:
    # unlike `succ`, `+` is opcode-only (never registered via
    # find_native_method — see integer.cr's own comment on this), so
    # dispatch_call has no native-method table entry to find for a
    # builtin-typed receiver like Integer/Float/String. This exists
    # for exactly that gap, the same way `compare`/`values_equal?`
    # already expose their own ValueOps operations generically rather
    # than leaving native code with no way to reach them at all.
    abstract def add(a : Value, b : Value) : Value

    # Calls a method by name on an arbitrary Value receiver, the same
    # way script code calling `recv.name(*args)` would — resolves
    # through the normal script-method-then-native dispatch order
    # (VM#dispatch_call), not just a fixed native table. Needed by
    # any native method that has to invoke a receiver's OWN method
    # generically rather than assuming a specific native
    # implementation — Range#each's #succ advance (see
    # builtins/range.cr) is the first user, since it must work for
    # any bound type that defines #succ, not just Integer.
    abstract def call_method(recv : Value, name : String, args : Array(Value)) : Value

    # Cycle guard for a recursive `inspect` — for ANY native method
    # that renders a container by recursing into elements it doesn't
    # own (`Array#inspect`, builtins/array.cr, is the first user; a
    # future `Hash#inspect` and any other native collection type are
    # expected to reach for this too, not just Array specifically).
    # Needed because rendering an element via ITS OWN real `inspect`
    # (rather than a hand-rolled per-type case) means a container
    # could recurse into itself, directly or through another
    # container — a genuinely self-referential array (`a = []; a <<
    # a; a.inspect`) would otherwise recurse until the native stack
    # overflows; real Ruby instead prints `[[...]]`. `obj_id` is the
    # CONTAINER'S OWN Crystal `object_id` (a `LabeledArray`/
    # `LabeledHash` is a `Reference`, so this is free) — not a Value's
    # own identity, since a `Value` is a struct rebuilt on every
    # access and has no stable identity of its own to key on.
    #
    # Block-based, not a begin_rendering/end_rendering pair a caller
    # has to remember to bracket correctly (an earlier draft of this
    # was exactly that pair — the block form exists specifically
    # because a paired API makes "forgot to release on the exception
    # path" a mistake every future caller could make individually,
    # where a block-based one makes the cleanup structural instead:
    # the ensure lives ONCE, inside the implementation, not
    # re-derived at every call site). Returns `cycle_result` (the
    # caller's own placeholder — `"[...]"` for Array, `"{...}"` for a
    # future Hash, or whatever else a future container's own
    # convention calls for) immediately without running the block at
    # all if `obj_id` is already being rendered; otherwise marks it as
    # rendering, runs the block, and always clears the mark again
    # before returning — even if the block raises.
    #
    # Global to the whole rendering call (one VM-level `Set`, not
    # reset between calls) — a cycle several levels deep (`a = []; b =
    # [a]; a << b`) needs the SAME tracking a direct self-reference
    # does, and only the top-level render call and its own recursive
    # `call_method("inspect", ...)` calls ever touch this, so leaking
    # across genuinely separate `p`/`puts`/interpolation calls isn't a
    # concern — each completes (or raises) before the next one
    # starts. This also means two DIFFERENT container types sharing
    # this same guard (an Array containing a Hash containing the same
    # Array again) are tracked correctly together, not as two
    # independent, blind guards.
    abstract def guard_rendering(obj_id : UInt64, cycle_result : String, & : -> String) : String

    # Lets a native function declare that one of its own arguments
    # (identified by a concrete ProvenanceKind + origin, not
    # necessarily an already-labeled Value) is the risky subject of
    # `tag`, feeding the same risk flow enforcement machinery
    # VM#call_native's automatic label-driven check uses (sorting,
    # RiskFlowDecisionRequest construction, the on_risk_flow_decision
    # callback, the script-catchable RiskFlowRejectedError raise).
    #
    # Exists because dynamic IFC alone has a real blind spot: it only
    # ever sees taint that flowed *through* a labeling call (like a
    # File IO module's read returning a labeled Value) — a script that
    # writes a sensitive-looking literal directly (`delete_file
    # ("/etc/passwd")`, no read_file/variable involved) produces no
    # label at all, and the automatic check has nothing to see. A sink
    # native function whose own argument IS the dangerous thing (a
    # path being deleted, a URL being posted to) should call this on
    # that argument's literal content directly, rather than relying on
    # the caller having pre-labeled it — see
    # research/IFC_DESIGN.md's enforcement design notes and
    # DEVELOPMENT.md's "Writing a ScriptModule" section for the
    # worked example this documents.
    #
    # `sensitivity`, when given, skips policy's sensitivity_for lookup
    # (the native function already knows it, e.g. it just computed a
    # value rather than looking one up); when nil, this method
    # performs the lookup itself.
    #
    # Returns the resolved `RiskFlowLabel` (`nil` if policy doesn't
    # consider `origin` sensitive at all) — see `VM#declare_sensitivity`'s
    # own comment for why this return value exists and matters: a
    # caller (a Legate verb, typically) needs it to tag the DATA it's
    # about to return, not just to have gated the call.
    abstract def declare_sensitivity(tag : RiskTag, kind : ProvenanceKind, origin : String,
                                     sensitivity : Sensitivity? = nil) : RiskFlowLabel?

    # Lets a native method raise a real, script-catchable diagnostic —
    # the SAME kind of error a script-level construct raises (an
    # ErrorCatalog `code`, substitution `data`, and the resulting Ruby
    # `error_class` to raise as, e.g. "ArgumentError") — rather than
    # letting a raw Crystal exception escape and get flattened into an
    # opaque internal N001 by `VM#call_native`'s catch-all rescue.
    #
    # Did not exist before `Integer#to_s(base)` needed it: every
    # native method up to that point either couldn't fail on bad input
    # (RiskProfile.none, pure data transforms) or accepted its
    # arguments' shape unconditionally. `to_s(base)` is the first
    # native method whose argument has a real invalid range a script
    # can pass and is expected to `rescue ArgumentError` for — real
    # Ruby does exactly that. General on purpose: any future native
    # method needing to reject bad input (a `TypeError`, another
    # `ArgumentError`, ...) uses this same path with its own catalog
    # code, rather than each one inventing its own ad hoc raise.
    abstract def raise_error(code : String, data : Hash(String, String) = {} of String => String,
                             error_class : String = "RuntimeError") : NoReturn

    # Same as `raise_error`, but for raising a real, dynamically-
    # computed message against a class that can't be resolved by name
    # — a NESTED class like `Legate::Malformed`, which is deliberately
    # never registered as a flat global (see Legate::Helpers.nest — it
    # resolves only via real `ConstPath` lookup, the same as any
    # script-defined `class A; class B; end; end`'s `A::B`), so
    # `raise_error`'s name-based `builtin_class_by_name` lookup can
    # never find it. Also deliberately NOT ErrorCatalog/Diagnostic-
    # coded like `raise_error` — that system is for ADJUTANT's OWN
    # fixed-template diagnostics; a caller needing this method
    # (Legate's own error messages: a path, a byte count, LEGATE.md
    # §9.1's "message MUST hint at" column) already has a real,
    # specific message computed and just needs it turned into a
    # real, catchable error object of the right class — the same
    # thing `raise ClassName, "msg"` does at the script level.
    # `attributes` attaches extra ivars to the error object alongside
    # its `message`, so a raised error can carry STRUCTURED data a
    # script reads programmatically rather than parses back out of a
    # sentence.
    #
    # Every native-raised error carried nothing but `message` before
    # this, which is fine for most of them — a `NotFound` has nothing
    # to say that the path in its message doesn't already say. It
    # stops being fine as soon as a script is expected to BRANCH on
    # something the error knows: an HTTP status, an exit code, a byte
    # count. Recovering those from a message means string-matching
    # prose that exists to be read by a human, and any rewording of
    # that prose silently breaks the script.
    #
    # The keys are plain ivar names WITHOUT a leading `@` or `__`
    # prefix (`"status"`, not `"@status"`), matching how
    # `message` itself is stored. Reader methods are the raising
    # side's responsibility: attaching an ivar makes the value
    # present, but a script can only reach it if the error's CLASS
    # defines a method returning it — see `Legate::Redirect` for the
    # pattern.
    #
    # Nothing validates that a class defines readers for the
    # attributes it is given. That is deliberate: an ivar with no
    # reader is inert rather than harmful, and requiring the two to
    # be declared together would mean this method needed to know
    # about class definitions.
    abstract def raise_error_class(message : String, error_class : RubyClass,
                                   attributes : Hash(String, Value)? = nil) : NoReturn
  end
end
