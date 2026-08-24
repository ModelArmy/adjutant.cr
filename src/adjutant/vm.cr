require "./bytecode"
require "./symbol_table"
require "./value"
require "./value_ops"
require "./ast"
require "./risk_flow_policy"
require "./risk_flow_decision"
require "./builtins/regexp"
require "./legate/exceptions"

module Adjutant
  # A compiled proc (method body or block).
  # Can be stored as a Value in the constant pool
  # and passed as a first-class script value.
  class ScriptProc
    getter chunk : Chunk
    getter name : String
    getter params : Array(String)
    getter local_count : Int32
    getter? is_block : Bool

    # The original AST this proc was compiled from — nil for procs that
    # don't have one (compiled directly from a Chunk in tests, etc.).
    # ast_body isn't used by the VM at all; kept solely so RiskWalker
    # can walk a method's actual control-flow shape (branches, loops)
    # rather than re-deriving it from bytecode jump targets. See
    # DEVELOPMENT.md's "Structured risk" section.
    #
    # ast_params IS read by the VM (VM#bind_args) — the param shapes
    # (`default`/`splat?`/`kwarg?`) that positional index-copy alone
    # can't see. nil only for RiskWalker's placeholder ScriptProcs
    # (never executed) and for procs built directly from a Chunk with
    # no AST at all — see bind_args's own plain-positional fallback
    # for that case.
    getter ast_body : Body?
    getter ast_params : Array(Param)?

    # The class/module this proc was lexically defined inside, captured
    # once when DefMethod registers it. nil for top-level functions and
    # for blocks (which are lexically transparent — see Frame#lexical_scope).
    property lexical_scope : RubyClass?

    def initialize(@chunk, @name, @params = [] of String, @local_count = 0, @is_block = false,
                   @ast_body = nil, @ast_params = nil)
    end
  end

  # A single begin/rescue/ensure construct's pending handler info,
  # while its body (or a nested one within it) is still running.
  # One entry per construct — not two independent entries in two
  # separate stacks — because a single `begin...rescue...ensure...end`
  # is one region with up to two jump targets, and the relative order
  # in which DIFFERENT constructs' entries were pushed must be
  # preserved to unwind correctly (checking "any pending rescue on
  # this frame" before "any pending ensure on this frame", regardless
  # of which was actually pushed more recently, can skip a more-nested
  # ensure that Ruby requires to run first).
  class HandlerEntry
    property rescue_ip : Int32?
    property ensure_ip : Int32?

    def initialize(@rescue_ip = nil, @ensure_ip = nil)
    end
  end

  # A single call frame on the VM stack.
  # A closure's view outward: one entry per enclosing lexical level,
  # nearest-first, each entry a REFERENCE to that level's own real
  # `Frame#locals` array (not a copy — mutations from arbitrarily deep
  # inside a closure must still land on the actual ancestor variable,
  # matching real Ruby's write-back semantics). Depth 0 is always
  # "whatever frame was running when this closure was created" — the
  # same array `Op::GetOuter`/`Op::SetOuter` indexed directly before
  # this existed. Built once, at closure-creation time, by prepending
  # the creating frame's own `locals` onto whatever chain THAT frame
  # itself already had (`CompilerScope#resolve_outer`'s own comment
  # has the compile-time half of this; see also SCOPE.md's "Closures
  # / block scoping" entry, the bug this fixes).
  alias OuterChain = Array(Array(Value))

  class Frame
    getter proc : ScriptProc
    getter chunk : Chunk
    property ip : Int32
    property line : Int32
    property stack_base : Int32
    getter filename : String
    property block : ScriptProc?
    # Stack of pending begin/rescue/ensure handler entries active in
    # this frame, most-recently-entered last. Op::Try pushes a new
    # entry (or Op::SetEnsure does, for an ensure-only construct);
    # Op::SetEnsure adds its target to the entry Op::Try just pushed
    # when both exist on the same construct. Op::EndTry clears the
    # rescue portion in place (leaving the ensure portion, if any, for
    # later) on the success path; Op::EnterEnsure pops the whole entry
    # once its ensure body is about to run — the single place an entry
    # is fully removed, whether reached via normal fallthrough or via
    # the unwind loop jumping in on error.
    getter handlers : Array(HandlerEntry)

    # Local variable slots — sized from ScriptProc#local_count at frame creation.
    getter locals : Array(Value)

    # Captured locals from the enclosing lexical chain (for block/lambda
    # closures) — nil for method frames. One entry per enclosing level;
    # see OuterChain's own comment above for the full shape and why it's
    # a chain of ARRAY REFERENCES, not one flattened/copied array.
    property outer_locals : OuterChain?

    # `self` for this frame — the receiver during an instance method call,
    # the class/module during a class body, or Value.nil_value at the
    # top level. Lives on the frame (not the VM) so it is automatically
    # isolated per call and restored on Op::Ret, with no manual save/restore.
    property self_val : Value

    # The lexical class/module scope for constant lookup when self isn't
    # a class/module directly (i.e. inside a method body or a block).
    # Methods get this from their ScriptProc (fixed at def-time, opaque
    # to the caller); blocks inherit it from the calling frame
    # (transparent) — see `call_script_proc`.
    property lexical_scope : RubyClass?

    # The locals array of the frame that was CURRENT when a block was
    # attached to the call that created this frame (see Op::SetBlock,
    # which snapshots current_frame.locals into @current_block_locals
    # at the moment a block literal is pushed as a call's block
    # argument — before Op::Call, so it's genuinely the block's
    # creation-site frame, not whatever's executing later). Op::Yield
    # reads THIS (not `locals`/`outer_locals`, which describe this
    # frame's own variables) when it eventually calls the block, so
    # the block correctly closes over the scope it was WRITTEN in
    # rather than whichever frame happens to be running `yield`.
    #
    # nil whenever this frame has no block (block was nil at
    # Op::SetBlock, or Op::Call ran with none pending at all).
    #
    # This is genuinely different from `outer_locals` above:
    # `outer_locals` is for when THIS frame's own proc IS a block,
    # closing over ITS creator. `block_outer_locals` is for a
    # DIFFERENT proc (the block passed TO this call) that this frame
    # might later `yield` to. Same OuterChain shape as `outer_locals`
    # — it becomes THAT block's own `outer_locals` once yielded to
    # (see Op::Yield), so the two have to agree on representation.
    property block_outer_locals : OuterChain?

    # Number of positional args the call that created this frame
    # actually supplied — set once in call_script_proc, read only by
    # Op::GetArgc (see that opcode's comment). Distinct from
    # `locals.size`/`proc.local_count`, both of which count DECLARED
    # slots (params + body locals) and never change; this is what the
    # CALLER actually passed, which is exactly what a default-param
    # prologue needs and locals (pre-filled with nil_value regardless)
    # cannot tell it.
    property argc : Int32

    # Names of the keyword args the call that created this frame
    # actually supplied — the by-name counterpart to `argc` above, set
    # once in call_script_proc and read only by Op::HasKwarg (see that
    # opcode's comment). nil for the overwhelming majority of calls,
    # which pass no keyword args at all.
    property kwarg_names : Set(String)?

    def initialize(@proc, @chunk, @stack_base, @filename, @block = nil, outer : OuterChain? = nil,
                   @self_val : Value = Value.nil_value, @lexical_scope : RubyClass? = nil,
                   @block_outer_locals : OuterChain? = nil, @argc : Int32 = 0)
      @ip = 0
      @line = 0
      @handlers = [] of HandlerEntry
      @locals = Array(Value).new(@proc.local_count, Value.nil_value)
      @outer_locals = outer
    end
  end

  # Execution limits — zero means unlimited.
  struct ExecutionLimits
    property instruction_limit : UInt64
    property call_depth_limit : Int32

    def initialize(
      @instruction_limit = 0_u64,
      @call_depth_limit = 256,
    )
    end
  end

  # RuntimeError raised when a script throws or hits a limit.
  class RuntimeError < Exception
    getter line : Int32
    getter filename : String
    # The script-visible error object (a RubyObject of a builtin or
    # user error class), when one was constructed. Falls back to a
    # plain string of `message` if nil — e.g. internal VM errors that
    # predate the typed-error hierarchy bootstrap.
    getter error_value : Value?

    # The host-facing structured report — nil when there isn't one, and
    # that case is PERMANENT, not a migration leftover.
    #
    # A `RuntimeError` covers two different things. Adjutant reporting a
    # failure it classified carries a diagnostic and a code. A script
    # raising its own error — `raise "boom"`, a re-raise from `ensure`,
    # the builtin `raise` — does not, and must not: the message belongs to
    # the script's author, and no catalog entry could say anything true
    # about it.
    #
    # So a nil diagnostic means "this is the script's error, not
    # Adjutant's". Do not try to make this non-nilable; doing so would
    # force a meaningless code onto every `raise` a script performs.
    #
    # Distinct from `error_value`, which is the object a SCRIPT rescues
    # and has to keep Ruby's semantics under the proper-subset mandate.
    # A diagnostic is a report ABOUT the failure, for whoever reads the
    # output.
    getter diagnostic : Diagnostic?

    def initialize(message : String, @filename = "<script>", @line = 0, cause = nil, @error_value = nil)
      @diagnostic = nil
      super(message, cause)
    end

    def initialize(message : String, frame : Frame, cause = nil, @error_value = nil)
      @filename = frame.filename
      @line = frame.line
      @diagnostic = nil
      super(message, cause)
    end

    def initialize(diagnostic : Diagnostic, frame : Frame, cause = nil, @error_value = nil)
      @diagnostic = diagnostic
      @filename = frame.filename
      @line = frame.line
      super(diagnostic.to_line, cause)
    end

    # For diagnostics raised outside the dispatch loop, where there is
    # no Frame — `require` failing to resolve a module, for instance.
    # Fabricating a Frame for those would mean inventing a proc and a
    # chunk that never existed.
    def initialize(diagnostic : Diagnostic, @filename : String, @line : Int32,
                   cause = nil, @error_value = nil)
      @diagnostic = diagnostic
      super(diagnostic.to_line, cause)
    end
  end

  # A VM-internal control-flow signal, NOT a subclass of RuntimeError
  # and never script-visible — `execute`'s own error-handling rescue
  # is typed `rescue ex : RuntimeError` specifically, so this passes
  # straight through it untouched, exactly as intended: a script-level
  # `rescue` (any class, including `rescue => e`/`rescue StandardError`)
  # must never be able to catch a `break`.
  #
  # Raised by Op::BlockBreak (a `break` with no enclosing loop
  # construct at compile time — i.e. `break` inside a block, not a
  # literal `while`/`for`/`until`/`loop`) and caught in EXACTLY ONE
  # place, `VM#call_native` — the single choke point every native
  # method/function call in the whole VM already funnels through (see
  # that method's own comment). That single catch point is what makes
  # this correct for nested native calls with no extra bookkeeping at
  # all: the signal is an ordinary Crystal `raise`, so it unwinds the
  # real Crystal call stack until the NEAREST enclosing `call_native`
  # catches it — which is always the innermost currently-running
  # native call, exactly matching real Ruby's own "break exits the
  # nearest call that received this block" semantics, including
  # correctly leaving an OUTER native call's own iteration undisturbed
  # (`outer.each { inner.each { break } }` — the inner `each` alone
  # terminates; from the outer `each`'s own Crystal loop's point of
  # view, its `ncc.invoke` call for that one element just returned an
  # ordinary Value, same as any other iteration). See SCOPE.md's
  # now-resolved "`break` inside a block passed to a NATIVE method...”
  # entry for the full bug this fixes, including why NO individual
  # native method (range.cr, array.cr, ...) needed a single line
  # changed — every one of them already just calls `ncc.invoke`
  # un-rescued, which is exactly right once the ONE catch point above
  # exists.
  class BlockBreakSignal < Exception
    getter value : Value

    def initialize(@value)
      super("break outside call_native — internal, should never surface to a script")
    end
  end

  # The bytecode VM.
  #
  # One VM instance per script execution. Holds the value stack,
  # call frame stack, globals, and execution state.
  class VM
    MAX_STACK = 4096

    # A single shared empty Chunk/ScriptProc pair, used only to build
    # a "sentinel" Frame for call_method's isolated execution (below)
    # — a frame that carries a real filename/line for diagnostics but
    # has NO bytecode of its own to run. Sharing one instance is safe:
    # nothing ever mutates a Chunk after construction, or reads
    # anything from this particular ScriptProc besides its (empty)
    # chunk.
    SENTINEL_CHUNK = Chunk.new
    SENTINEL_PROC  = ScriptProc.new(SENTINEL_CHUNK, "<native>")

    getter instruction_count : UInt64
    getter globals : Hash(Int32, Value)
    getter risk_flow_log : RiskFlowLog
    getter risk_flow_policy : RiskFlowPolicy
    getter on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision

    def initialize(
      @symbols : SymbolTable,
      @limits : ExecutionLimits = ExecutionLimits.new,
      @effect : EffectHandler? = nil,
      @interpreter : Interpreter? = nil,
      @globals : Hash(Int32, Value) = {} of Int32 => Value,
      @risk_flow_log : RiskFlowLog = RiskFlowLog.new,
      @risk_flow_policy : RiskFlowPolicy = RiskFlowPolicy.reject_all,
      @on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision = ->(_req : RiskFlowDecisionRequest) { RiskFlowDecision::Reject },
    )
      @stack = Array(Value).new(256)
      @frames = [] of Frame
      @instruction_count = 0_u64
      @current_block = nil.as(ScriptProc?)
      # The locals array of the frame active when @current_block was
      # attached via Op::SetBlock — i.e. the block's true creation
      # site. Threaded through dispatch_call/call_script_proc onto the
      # CALLEE's frame (as Frame#block_outer_locals) so a later
      # Op::Yield inside that callee correctly closes the block over
      # where it was WRITTEN, not over whatever frame happens to be
      # running yield. See Op::SetBlock, Op::Yield, and Frame#
      # block_outer_locals's own comment for the full mechanism.
      @current_block_locals = nil.as(OuterChain?)
      # Keyword args staged by Op::SetKwargNames for the Call that
      # immediately follows — the by-name counterpart to
      # @current_block above, same transient "stage, consume, clear"
      # lifecycle, just carrying named values instead of a proc. nil
      # whenever the pending call has no keyword args at all (the
      # overwhelming majority), since Op::SetKwargNames is only
      # emitted when there are some.
      @pending_kwargs = nil.as(Hash(String, Value)?)
      # Value of the most recently caught error, for Op::PushError.
      # A RubyObject of the raised/builtin error class when one was
      # constructed (see RuntimeError#error_value); a plain string for
      # internal errors that don't yet go through the typed hierarchy.
      @last_error = Value.nil_value
      # Set by the unwind loop when it jumps into an ensure body while
      # an error is propagating (not on the normal success path).
      # Op::EndEnsure re-raises it once the ensure body finishes,
      # unless the ensure body itself raised a new error first — in
      # which case that error supersedes it (Ruby semantics) and this
      # never gets read; it's cleared at the top of every fresh catch
      # so it can't leak into an unrelated later error.
      @pending_reraise = nil.as(Value?)
      # Backing store for NativeCallContext#guard_rendering (see that
      # method's own comment for the full reasoning) — one VM-level
      # Set, not per-call state, since a recursive inspect walks back
      # OUT through the VM (via `call_method`) between each container
      # level, so there's nowhere else to durably hold "currently
      # rendering" across those calls.
      @rendering_ids = Set(UInt64).new
    end

    # Execute a compiled chunk and return the result.
    def run(chunk : Chunk, filename : String = "<script>", local_count : Int32 = 0) : Value
      # Not a RuntimeError: this fires before any script runs, so no
      # script could rescue it, and the fault is the host's wiring.
      unless @frames.empty?
        raise HostStateError.new(Diagnostic.new(code: "H005"))
      end
      main_proc = ScriptProc.new(chunk, "<main>", local_count: local_count)
      # self at top level is `main` — a real RubyObject of class
      # Object, matching real Ruby (see Interpreter#main's own
      # comment). Falls back to nil_value only for a VM built without
      # an Interpreter (no Object class exists to construct `main`
      # from in that configuration) — a top-level `def` in that setup
      # correctly raises "def outside of a class/module body", same
      # as it always has, since there's genuinely nothing for it to
      # attach to.
      self_val = @interpreter.try { |i| Value.robject(i.main) } || Value.nil_value
      push_frame(main_proc, filename, self_val: self_val)
      execute
    end

    # Execute a compiled script proc and return the result.
    # Can be called from within an execution via a native function.
    # Yield / call a live call-site block (`{ }`/`do...end`) from a
    # native function — Array#each/Range#each/Hash#each's `blk` param,
    # etc. Always uses the CURRENT frame's locals as the block's outer
    # scope, which is correct here (not just convenient) because a
    # `blk : ScriptProc` a native function receives is only ever
    # invoked synchronously, inside the very call that received it,
    # while its defining frame is still live on `@frames` — Adjutant
    # has no `&blk`-param capture or block-forwarding at all (see
    # UNSUPPORTED.md, U001), so there is no way for this frame to have
    # gone anywhere by the time this runs. If block-forwarding is ever
    # added, this assumption needs to be re-examined — don't assume it
    # still holds. See array_spec.cr's "resolves an outer local...
    # through an intervening method call" for the regression this is
    # paired with.
    #
    # For a STORED `Proc` value (from a `->(){}` lambda literal,
    # possibly called long after and from a different frame than the
    # one that defined it — e.g. Proc#call), use `invoke_proc` instead,
    # never this method directly: that lambda's real closure snapshot
    # lives on its own RubyObject (RubyObject#outer_locals, taken by
    # Op::MakeProc at the lambda's true creation site), not on
    # whichever frame happens to be calling it now. This method has no
    # way to accept that snapshot on purpose — the split exists so a
    # native method calling a Proc can't silently forget to pass it
    # (see the 2026-07-20 closure-capture bug, research/IFC_DESIGN.md,
    # and the follow-up conversation on this same VM#invoke that led
    # to this split).
    protected def invoke(proc : ScriptProc, args : Array(Value), self_val : Value? = nil,
                         kwargs : Hash(String, Value)? = nil) : Value
      invoke_internal(proc, args, self_val, outer_locals: nil, kwargs: kwargs)
    end

    # The only correct way for a native function to call a stored
    # `Proc` object (as opposed to a live call-site block — see
    # `invoke` above). Takes the `Proc` RubyObject itself, not a bare
    # ScriptProc, specifically so the caller never sees or has to
    # remember to pass a raw outer_locals array — it's pulled from
    # `proc_obj.outer_locals` internally, the one place it can't be
    # forgotten. `Proc#call` (builtins/proc.cr) is the first and, as
    # of 2026-07-20, only caller; any future native method that
    # accepts a Proc argument and wants to call it should use this,
    # not `invoke` + a manually-extracted ScriptProc.
    #
    # `proc_obj` must actually be a Proc instance (rclass == Proc) —
    # anything else has no `__sproc` ivar and would otherwise fail
    # with a raw Crystal KeyError or TypeCastError, neither of which
    # is an Adjutant::RuntimeError a script can catch or a native-
    # method author gets a useful message from. Checked explicitly
    # rather than left to fail naturally, since this method is called
    # with a caller-supplied RubyObject (a native function's own
    # argument), unlike invoke's ScriptProc, which is always sourced
    # from a trusted internal `blk` param.
    protected def invoke_proc(proc_obj : RubyObject, args : Array(Value), self_val : Value? = nil) : Value
      unless proc_obj.rclass == builtin_class_by_name("Proc")
        # An H code, not an I: `invoke_proc` is exposed through
        # NativeCallContext, so the caller is always a host-provided
        # native function passing the wrong Value. Telling an integrator
        # to report their own mistake upstream would be wrong.
        #
        # Because that is the ONLY way here, this always unwinds through
        # `call_native`'s rescue and reaches the reader as N001 carrying
        # this H004 as its message. That is the useful shape — it names
        # both the function that failed and why — but it does mean H004
        # is never seen on its own, and that the result IS script-
        # rescuable, since N001 is a RuntimeError.
        #
        # Kept as a HostArgumentError rather than a RuntimeError anyway:
        # the classification is what is true about the failure, and it
        # stays correct if invoke_proc ever becomes reachable elsewhere.
        raise HostArgumentError.new(
          Diagnostic.new(code: "H004", data: {"found" => proc_obj.rclass.name})
        )
      end
      sproc = proc_obj.ivars[@symbols.intern("__sproc").value].as_proc
      invoke_internal(sproc, args, self_val, outer_locals: proc_obj.outer_locals)
    end

    # Wraps a live call-site block into a real `Proc` RubyObject — see
    # `NativeCallContext#wrap_block_as_proc`'s own comment for the
    # full reasoning (`lambda`/`proc`, builtins/proc.cr, are the only
    # callers). `current_frame` here IS the call-site frame `lambda`/
    # `proc` was itself called from, unchanged, because a native call
    # never pushes a VM frame of its own — exactly the same frame
    # `Op::MakeProc`'s own a=1 branch captures from for an ordinary
    # `->(){}` literal (see that opcode's comment), so this reuses
    # `make_lambda_object` directly rather than a parallel
    # implementation. `label` is passed as `nil` — the returned Proc
    # object gets no risk-flow label of its own; nothing about
    # wrapping an existing block into a Proc constitutes a new
    # sensitive value in its own right, unlike, say, a value actually
    # read from an argument.
    protected def wrap_block_as_proc(blk : ScriptProc, filename : String, line : Int32) : Value
      f = current_frame
      make_lambda_object(blk, nil, [f.locals] + (f.outer_locals || [] of Array(Value)), filename, line)
    end

    # Shared machinery for both `invoke` and `invoke_proc` above —
    # never called directly from outside this file. `outer_locals`,
    # when given, overrides the outer/closure scope the invoked proc
    # sees; when nil, falls back to the CURRENT frame's locals. See
    # `invoke`'s and `invoke_proc`'s own comments for which to use and
    # why — this method itself doesn't enforce the distinction, its
    # two public callers do, by construction (only invoke_proc can
    # supply a non-nil override, since only it has a RubyObject to
    # pull one from).
    private def invoke_internal(proc : ScriptProc, args : Array(Value), self_val : Value? = nil,
                                outer_locals : OuterChain? = nil, kwargs : Hash(String, Value)? = nil) : Value
      saved_frames = @frames
      saved_stack = @stack
      saved_ins_count = @instruction_count
      saved_cur_block = @current_block
      saved_cur_block_locals = @current_block_locals
      saved_pending_kwargs = @pending_kwargs
      result = Value.nil_value
      begin
        f = current_frame # before replacing @frames
        inherited_self = self_val || f.self_val
        inherited_lexical = proc.lexical_scope || f.lexical_scope
        # No explicit override (the ordinary `invoke` path — a native
        # function calling a live call-site block, not a stored Proc)
        # falls back to whatever frame is CURRENTLY running — but that
        # frame might ITSELF be a closure with its own outer reach
        # (exactly `two_level_block`'s shape: a native `each` call
        # invoking its block while an OUTER block's own native `each`
        # call is still on the stack). f.locals alone would only ever
        # see that immediate frame's own locals — chaining in
        # f.outer_locals too (its own captured reach, if any) is the
        # same fix Op::SetBlock/Op::MakeProc needed, for the same
        # reason. See OuterChain's own comment.
        effective_outer = outer_locals || ([f.locals] + (f.outer_locals || [] of Array(Value)))
        @frames = [] of Frame
        # @stack must be isolated too, not just @frames — execute's
        # Op::Ret pushes its result back onto @stack only `unless
        # @frames.empty?` (correct for ordinary same-@frames-array
        # nesting, where the caller's frame is still present after
        # Op::Ret pops the callee's), but invoke's swapped, single-
        # frame @frames IS empty immediately after that one frame's
        # Op::Ret — so the result is popped and never pushed back, and
        # execute's own `@stack.last? || result` fallback (its actual
        # return mechanism) then reads whatever the CALLER's stack
        # happened to have on top instead: stale, not this call's
        # result. Concretely: sq.call(2) leaves 4 on the shared stack
        # mid-array-literal-construction; a nested sq.call(3) then
        # incorrectly returns that leftover 4 instead of its own 9,
        # since its own Op::Ret result never made it onto the (shared)
        # stack at all. Swapping @stack the same way @frames already
        # is gives the nested execute a clean slate whose top really
        # is its own Op::Ret result, restoring the caller's stack
        # (with the outer expression's in-progress values intact)
        # afterward. Found 2026-07-18 via the person's
        # spec/scripts/expressions.rb repro — direct sequential
        # `.call`s worked (stack was momentarily balanced between
        # them), only a compound expression with values still
        # pending ON the stack (array literal, method args, ...)
        # around a nested `.call` exposed it.
        @stack = Array(Value).new(256)
        call_script_proc(proc, args, f.filename, nil, effective_outer, self_val: inherited_self,
          lexical_scope: inherited_lexical, lexical_override: true, kwargs: kwargs)
        # Let the VM execute the chunk
        result = execute
      ensure
        @frames = saved_frames
        @stack = saved_stack
        @instruction_count = saved_ins_count
        @current_block = saved_cur_block
        @current_block_locals = saved_cur_block_locals
        @pending_kwargs = saved_pending_kwargs
      end
      result
    end

    # Register a global variable by name.
    def set_global(name : String, value : Value) : Nil
      sym = @symbols.intern(name)
      @globals[sym.value] = value
    end

    # Resolve the class to use for class-variable access from the given
    # frame's self: the object's class if self is an instance, self
    # Shared by the "is_a?"/"kind_of?" exec_builtin case. Three
    # receiver shapes, matching "class"'s own three-way split:
    #   - a RubyObject instance: walk its own rclass's superclass chain
    #     (e.g. `Foo.new.is_a?(Object)`)
    #   - a RubyClass itself: walk ITS rclass's superclass chain, NOT
    #     its own superclass chain — `Integer.is_a?(Class)` asks
    #     "is Integer's class Class-or-an-ancestor", the same
    #     question `5.is_a?(Integer)` asks starting from 5's class,
    #     not "is Integer's SUPERCLASS Class" (a different, wrong
    #     question — Integer.superclass is Object, never Class)
    #   - any other builtin-kind Value: Interpreter#builtin_class_for
    # ameba:disable Naming/PredicateName - deliberately named to echo is_a?/kind_of?, not a generic predicate
    private def is_a_target?(recv : Value, target : RubyClass?) : Bool
      start_cls = recv.as_robject?.try(&.rclass) ||
                  recv.as_rclass?.try(&.rclass) ||
                  @interpreter.try(&.builtin_class_for(recv))
      return false unless start_cls && target
      cls = start_cls.as(RubyClass?)
      while cls
        return true if cls == target
        # `included_modules` — found missing while building
        # Legate::Stream (a real `include`d module, not simulated;
        # `find_native_method` already correctly walks this same list
        # for METHOD RESOLUTION, confirmed earlier — `is_a?` simply
        # never got the equivalent check). Direct includes only, not
        # a module's own nested includes expanded transitively — real
        # Ruby's `ancestors` does expand those, but nothing in
        # Adjutant includes-a-module-that-itself-includes-a-module yet
        # for that gap to matter in practice; worth revisiting if one
        # ever does.
        return true if cls.included_modules.includes?(target)
        cls = cls.superclass
      end
      false
    end

    # Shared by `triple_eq_matches?`'s Range branch (below).
    # `true` only for a genuine Range instance — every other robject
    # (including one that happens to define its own ivars named
    # `__min` etc., unlikely but not impossible) must NOT match, so
    # this checks the actual rclass identity via builtin_class_by_name
    # rather than duck-typing on ivar presence.
    private def range_receiver?(v : Value) : Bool
      obj = v.as_robject?
      !!(obj && obj.rclass == builtin_class_by_name("Range"))
    end

    # Bound check for Range#=== — real Ruby's own logic: `min <= x`
    # (or `min < x` doesn't apply; Range has no exclusive-start
    # concept) and, depending on exclusivity, `x < max` or `x <= max`.
    # Goes through `compare` (not `ValueOps` directly) so a
    # Comparable-style custom bound type dispatches through its own
    # `<=>` here too — see this method's own doc comment above.
    # Ivar names/lookup mirror make_range_object's own (vm.cr, further
    # down) and builtins/range.cr's accessors — all three must stay in
    # sync on the `__min`/`__max`/`__exclusive` naming.
    #
    # `min`/`max` explicit `null?` checks — a beginless/endless range
    # (`compile_range`'s own comment: a missing bound compiles to a
    # real `Value.nil_value`, stored as-is) has NO bound to check on
    # that side at all, and `nil` isn't a value `compare`/
    # `ValueOps.compare` know how to pair against anything — every one
    # of `ValueOps.compare`'s type-pair branches requires both sides
    # to be a real Int/Float/String, so a `nil` operand falls through
    # to that `case`'s own `else -> false`, silently answering "not
    # included" for EVERY `x`, regardless of whether `x` actually
    # satisfies the range's one real bound. Found 2026-08-22 (SCOPE.md,
    # now-resolved Must Fix entry) while uncommenting `spec/scripts/
    # mruby/range.rb`'s own `Range#===` test — `(..10) === 5` answered
    # `false` instead of `true`, no error, silent. A missing bound
    # means "always satisfied on this side," checked directly here
    # rather than routed through `compare` at all — there's no
    # principled way for `compare`/`ValueOps.compare` to special-case
    # "this side doesn't apply" from a bare `nil` alone, so the check
    # belongs at this caller, which already knows which ivar is
    # missing and what that means.
    private def range_include?(range : Value, x : Value) : Bool
      obj = range.as_robject
      min = obj.ivars[@symbols.intern("__min").value]
      max = obj.ivars[@symbols.intern("__max").value]
      exclusive = obj.ivars[@symbols.intern("__exclusive").value].as_bool
      return false unless min.null? || compare(x, min, :>=)
      return true if max.null?
      exclusive ? compare(x, max, :<) : compare(x, max, :<=)
    end

    # `true` only for a genuine Proc instance (a real lambda, or
    # `lambda { }` — see builtins/proc.cr's own doc comment on what
    # can reach this shape) — same identity-not-duck-typing check
    # `range_receiver?` just above uses for Range, for the same
    # reason: an ordinary robject that happens to carry an ivar named
    # `__sproc` (unlikely, but not impossible) must not match.
    private def proc_receiver?(v : Value) : Bool
      obj = v.as_robject?
      !!(obj && obj.rclass == builtin_class_by_name("Proc"))
    end

    # `Op::TripleEq`'s actual matching logic — real Ruby's `pattern ===
    # subject`, called (in THIS argument order) from both `Op::TripleEq`'s
    # own VM handler (bare infix `a === b`) and `compile_case`'s
    # per-`when`-pattern check, the two and ONLY two ways to reach this
    # opcode (see `compile_triple_eq`'s own comment on why the two call
    # sites' stack orders differ but both resolve to this same
    # `(pattern, subject)` parameter order before calling here).
    #
    # Deliberately NOT method dispatch — `===` joined `==` in
    # `OVERLOADABLE_OPERATOR_NAMES` (compiler.cr), so unlike `<=>`/`=~`
    # (real receiver-based `Op::Call`s, `compile_spaceship`/
    # `compile_match`), no script class can define its own `===` for
    # this to ever consult, and this hardcoded set is deliberately
    # closed, not extensible via a method table the way, say, `#to_s`
    # is — same reasoning `Op::Eq`'s `values_equal?` already commits to
    # for `==`. A future native type wanting its own `===` semantics
    # here needs a new branch added directly, not a `native_methods`
    # registration.
    #
    # This IS the sole source of truth for Regexp matching under
    # `===`/`case-when` — deliberately NOT calling through to
    # `RegexpObject`'s own genuine native `#===`/`#match?` method
    # (builtins/regexp.cr had one; removed alongside this — see
    # SCOPE.md). Real Ruby's Regexp#=== dispatches through a real,
    # overridable method; Adjutant's doesn't, matching the "no
    # overloading" decision this whole opcode exists to enforce. A
    # `Regexp` pattern used via dot-call (`/re/.===(str)`) now raises
    # a plain undefined-method error instead — consistent with `a.==
    # (b)`, `a.+(b)`, etc., which have never worked either (no
    # `exec_builtin` case for `"=="` at all).
    private def triple_eq_matches?(pattern : Value, subject : Value) : Bool
      if cls = pattern.as_rclass?
        # `Class#===`/`Module#===` — is-instance-of. Real Ruby:
        # `SomeClass === x` and `x.is_a?(SomeClass)` ask the exact same
        # question, just with the receiver/target roles swapped —
        # reuse `is_a_target?` rather than re-deriving the same
        # three-receiver-shape walk it already does.
        is_a_target?(subject, cls)
      elsif range_receiver?(pattern)
        # `Range#===` — is-member-of. Bound check goes through
        # `compare` (this file, above — the same dispatch `<=>`'s own
        # item wired up), not `ValueOps` directly, so a
        # Comparable-style custom bound type works here for free,
        # exactly like Range#each already gets for #succ.
        range_include?(pattern, subject)
      elsif (robj = pattern.as_robject?) && robj.is_a?(RegexpObject)
        # `Regexp#===` — real match test, hardcoded here (see this
        # method's own doc comment on why, above).
        str = subject.as_string?
        str ? robj.regex.matches?(str) : false
      elsif proc_receiver?(pattern)
        # `Proc#===` — call the proc/lambda with `subject`, truthiness
        # of the result is the match. Real Ruby's own `Proc#===`,
        # exactly this: `->(x) { x.even? } === 4`. `case n; when
        # ->(x) { x.even? }` is the idiomatic use — added here rather
        # than left for later, since Adjutant already has real,
        # working lambdas (builtins/proc.cr) for this to be reachable
        # through today, not a stub for a future feature.
        invoke_proc(pattern.as_robject, [subject]).truthy?
      else
        # Every other pattern: real Ruby's own default `Object#===`
        # genuinely is `==` — not a fallback standing in for a missing
        # feature, the actually-correct behavior here.
        values_equal?(subject, pattern)
      end
    end

    # String#[range] — real Ruby's own substring-slicing rules:
    # negative bounds count from the end (same as the plain-Integer
    # index case just above); a start beyond the string's length
    # returns nil (out of bounds), but a start EXACTLY AT the length
    # is a valid edge case returning "" (e.g. `"abc"[3..5] == ""`);
    # an end beyond the length clamps to the last valid index rather
    # than erroring. Only Integer bounds are handled — Range
    # construction itself allows any orderable bound type (see
    # bootstrap_range's own comment), but a non-Integer bound has no
    # meaningful string-slicing interpretation, so this falls back to
    # nil rather than raising (matching exec_get_index's own general
    # "can't resolve this shape" -> nil convention elsewhere).
    #
    # Ivar names/lookup mirror range_include?'s own (just above) and
    # builtins/range.cr's accessors — all three must stay in sync on
    # the `__min`/`__max`/`__exclusive` naming.
    private def exec_get_index_string_range(target : Value, range : Value) : Value
      obj = range.as_robject
      lo_val = obj.ivars[@symbols.intern("__min").value]
      hi_val = obj.ivars[@symbols.intern("__max").value]
      exclusive = obj.ivars[@symbols.intern("__exclusive").value].as_bool
      return Value.nil_value unless lo_val.int? && hi_val.int?

      s = target.as_string
      lo = lo_val.as_int.to_i
      hi = hi_val.as_int.to_i
      lo += s.size if lo < 0
      return Value.nil_value if lo < 0 || lo > s.size

      hi += s.size if hi < 0
      hi -= 1 if exclusive
      hi = s.size - 1 if hi >= s.size
      return Value.string("", target.label) if hi < lo

      Value.string(s[lo..hi], target.label)
    end

    # Shared by the "respond_to?" exec_builtin case — mirrors
    # dispatch_call's own receiver-based resolution order (RubyObject:
    # find_method then find_native_method; RubyClass: find_singleton_
    # method then find_native_singleton_method; builtin value:
    # find_native_method via builtin_class_for) without actually
    # invoking anything.
    private def script_responds_to?(recv : Value, method_name : String) : Bool
      sym = @symbols.lookup(method_name)
      return false unless sym
      sym_id = sym.value
      if obj = recv.as_robject?
        cls = obj.rclass
        !!(cls.find_method(sym_id) || cls.find_native_method(sym_id))
      elsif cls = recv.as_rclass?
        !!(cls.find_singleton_method(sym_id) || cls.find_native_singleton_method(sym_id))
      elsif interp = @interpreter
        !!(interp.builtin_class_for(recv).try(&.find_native_method(sym_id)))
      else
        false
      end
    end

    # itself if self is a class/module body. Raises outside a class
    # context — Ruby doesn't support cvars there either.
    private def cvar_class(f : Frame) : RubyClass
      if obj = f.self_val.as_robject?
        return obj.rclass
      end
      if cls = f.self_val.as_rclass?
        return cls
      end
      raise runtime_diagnostic(
        Diagnostic.new(code: "R002", primary: frame_span(f)), f
      )
    end

    # Reads @name off `self` — a RubyObject's own ivars for an
    # instance, or a RubyClass's separate class-ivar table when self
    # IS the class (class body / `def self.foo`). Anything else
    # (self is nil, a plain value, ...) silently reads nil, matching
    # Ruby's forgiving ivar semantics outside an object context.
    private def read_ivar(self_val : Value, sym_id : Int32) : Value
      if obj = self_val.as_robject?
        return obj.ivars[sym_id]? || Value.nil_value
      end
      if cls = self_val.as_rclass?
        return cls.get_ivar(sym_id) || Value.nil_value
      end
      Value.nil_value
    end

    # Writes @name onto `self`, same branching as read_ivar. A write
    # with no valid self (nil, a plain value, ...) silently no-ops,
    # same forgiving semantics as the read side.
    private def write_ivar(self_val : Value, sym_id : Int32, val : Value) : Nil
      if obj = self_val.as_robject?
        obj.ivars[sym_id] = val
        return
      end
      if cls = self_val.as_rclass?
        cls.set_ivar(sym_id, val)
      end
    end

    private def push_frame(proc : ScriptProc, filename : String, block : ScriptProc? = nil, stack_base : Int32 = @stack.size,
                           outer : OuterChain? = nil, self_val : Value = Value.nil_value, lexical_scope : RubyClass? = nil,
                           block_outer_locals : OuterChain? = nil, argc : Int32 = 0) : Frame
      if @limits.call_depth_limit > 0 && @frames.size >= @limits.call_depth_limit
        raise script_diagnostic("L002", {"limit" => @limits.call_depth_limit.to_s}, current_frame)
      end
      frame = Frame.new(proc, proc.chunk, stack_base, filename, block, outer, self_val, lexical_scope, block_outer_locals, argc)
      @frames.push(frame)
      frame
    end

    private def pop_frame : Frame
      @frames.pop
    end

    private def current_frame : Frame
      @frames.last
    end

    # Exposes the CURRENTLY RUNNING frame's own `self` to a native
    # function — needed by any native method reached via
    # `dispatch_call`'s implicit-self/self-is-rclass branch (a bare
    # call made from inside a class/module body, e.g. `include Foo`),
    # since THAT dispatch path (unlike the explicit-receiver one) never
    # prepends a receiver into `args` at all — `call_native` has no
    # `self_val` parameter of its own. Native functions execute
    # in-line, without pushing their own Frame, so `current_frame`
    # here is genuinely still the CALLING frame — the one whose
    # `self_val` is exactly what "self" means at the call site.
    # `protected`, not `private`, so `NativeFunctionCall`
    # (native_function_call.cr, this module's only `NativeCallContext`
    # implementor) can call it — same visibility as `invoke`/
    # `call_method`/`compare`, which already do this for their own
    # reasons.
    protected def current_self_val : Value
      current_frame.self_val
    end

    private def push(v : Value) : Nil
      raise script_diagnostic("L003", {"limit" => MAX_STACK.to_s}, current_frame) if @stack.size >= MAX_STACK
      @stack.push(v)
    end

    private def pop : Value
      if @stack.size <= current_frame.stack_base
        raise runtime_diagnostic(
          Diagnostic.new(code: "I003", primary: frame_span(current_frame))
        )
      end
      @stack.pop
    end

    private def peek : Value
      @stack.last
    end

    private def tick : Nil
      @instruction_count += 1
      if @limits.instruction_limit > 0 && @instruction_count > @limits.instruction_limit
        raise script_diagnostic("L004", {"limit" => @limits.instruction_limit.to_s}, current_frame)
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def execute : Value
      result = Value.nil_value

      loop do
        break if @frames.empty?
        f = current_frame
        chunk = f.chunk

        break if f.ip >= chunk.code.size

        inst = chunk.code[f.ip]
        f.ip += 1
        f.line = inst.line
        tick

        begin
          case inst.op
          when Op::Noop
            # nothing

          when Op::Const
            push(chunk.consts[inst.c])
          when Op::Pop
            @stack.pop if @stack.size > f.stack_base
          when Op::Dup
            push(peek)
            # --- Globals --------------------------------------------------------

          when Op::GetGlobal
            sym = chunk.consts[inst.c].as_sym
            gval = @globals[sym.value]?
            if gval && !gval.proc?
              # A plain data global ($foo-style or otherwise pre-set) —
              # push its value as-is. Not a call attempt. (@globals now
              # holds only constants/classes in practice — see the
              # 2026-07-16 root-scope work — so `gval` here is really
              # always a RubyClass; this branch is kept general rather
              # than narrowed, since nothing stops a future feature
              # from writing a genuine data global here too.)
              push(gval)
            else
              # Not a resolvable local (checked earlier at compile
              # time — see compile_identifier), and not a plain data
              # global either. Matching real Ruby, treat this as an
              # implicit zero-arg method call attempt: self's own
              # methods first (a top-level def, now a real method of
              # Object — see Interpreter#main/dispatch_call's
              # implicit-self step), then native functions (also on
              # Object's own native_methods table), then builtins, and
              # NameError (script-catchable) if none match. `def`s no
              # longer live in @globals at all — this single
              # dispatch_call covers them via implicit self, not via
              # any @globals lookup.
              depth_before = @frames.size
              result = dispatch_call(sym.name, [] of Value, safe: false,
                filename: f.filename, line: inst.line, self_val: f.self_val)
              push(result) if @frames.size == depth_before
            end
          when Op::SetGlobal
            sym = chunk.consts[inst.c].as_sym
            val = pop
            @globals[sym.value] = val
            push(val)

            # --- Instance / class variables ------------------------------------
            # Ivars live on self — a RubyObject's own ivars table for an
            # instance, or a RubyClass's separate class-ivar table when
            # self is the class itself (class body statements, and
            # `def self.foo` singleton methods). These are genuinely
            # different slots even for the same @name (see
            # RubyClass#get_ivar/#set_ivar) — not a fallback or a
            # simplification. Reading/writing outside either context
            # silently no-ops to nil, matching Ruby's forgiving ivar
            # semantics. Cvars live on self's class, walking the
            # superclass chain (see RubyClass#get_cvar/#set_cvar); outside
            # a class context this is unsupported, so it raises.

          when Op::GetIvar
            sym = chunk.consts[inst.c].as_sym
            push(read_ivar(f.self_val, sym.value))
          when Op::SetIvar
            sym = chunk.consts[inst.c].as_sym
            val = pop
            write_ivar(f.self_val, sym.value, val)
            push(val)
          when Op::GetCvar
            sym = chunk.consts[inst.c].as_sym
            cls = cvar_class(f)
            push(cls.get_cvar(sym.value) || Value.nil_value)
          when Op::SetCvar
            sym = chunk.consts[inst.c].as_sym
            val = pop
            cvar_class(f).set_cvar(sym.value, val)
            push(val)

            # --- Constants -------------------------------------------------------
            # Lexically scoped: walk the innermost enclosing class/module
            # (self if we're directly in a class/module body, else the
            # defining proc's lexical_scope), then fall back to top-level
            # globals.

          when Op::GetConstant
            sym = chunk.consts[inst.c].as_sym
            start = f.self_val.as_rclass? || f.lexical_scope
            val = start.try(&.find_constant(sym.value)) || @globals[sym.value]?
            unless val
              raise undefined_constant(sym.name, f)
            end
            push(val)
          when Op::SetConstant
            sym = chunk.consts[inst.c].as_sym
            val = pop
            target = f.self_val.as_rclass? || f.lexical_scope
            # Constants are assign-once — real Ruby only WARNS on
            # reassignment (still permits it); Adjutant deliberately
            # makes it a hard error instead (2026-07-18, ahead of
            # Piece D — see SCOPE.md's Must Fix history and
            # UNSUPPORTED.md's U003, class/module reopening). This is what
            # makes a constant-valued Lambda (`F1 = ->(){}`) passed as
            # a call argument staticaly resolvable at all: the walker
            # can trust that whatever `F1` resolves to during a walk is
            # what it'll still be at runtime, because nothing else in
            # the same script could have quietly changed it first.
            #
            # Applies uniformly to BOTH branches below: a top-level
            # `FOO = 5` (no enclosing class/module body) has `target ==
            # nil` here — main is a RubyObject, not a RubyClass, so
            # `self_val.as_rclass?` is nil, and top-level code's
            # lexical_scope is nil too (only a `def`'s own body proc
            # ever gets lexical_scope assigned — see Op::DefMethod/
            # Op::DefSingleton) — so it goes through @globals, same as
            # a top-level `class Foo; end`. A constant defined INSIDE a
            # class/module body goes through target.constants instead.
            # Both need the same check; this isn't specific to classes.
            if target
              if existing = target.constants[sym.value]?
                raise constant_reassignment(existing, val, "#{target.name}::#{sym.name}", f)
              end
              target.constants[sym.value] = val
            else
              if existing = @globals[sym.value]?
                raise constant_reassignment(existing, val, sym.name, f)
              end
              @globals[sym.value] = val
            end
            push(val)
          when Op::GetConstantFrom
            sym = chunk.consts[inst.c].as_sym
            ns_val = pop
            unless ns = ns_val.as_rclass?
              raise script_diagnostic("R004", {"value" => ns_val.to_s}, f)
            end
            val = ns.constants[sym.value]?
            unless val
              raise undefined_constant("#{ns.name}::#{sym.name}", f, bare_name: sym.name)
            end
            push(val)
          when Op::GetGlobalConstant
            sym = chunk.consts[inst.c].as_sym
            val = @globals[sym.value]?
            unless val
              raise undefined_constant(sym.name, f)
            end
            push(val)

            # --- Stack ops ------------------------------------------------------
          when Op::GetIndex
            idx = pop
            target = pop
            push(exec_get_index(target, idx, safe: false, filename: f.filename, line: inst.line))
          when Op::SafeIndex
            idx = pop
            target = pop
            push(exec_get_index(target, idx, safe: true, filename: f.filename, line: inst.line))
          when Op::SetIndex
            val = pop
            idx = pop
            target = pop
            exec_set_index(target, idx, val)
            @risk_flow_log.record("SetIndex", [target.label, val.label], target.label, f.line)
            push(val)
          when Op::SetIndexFromValue
            # See emit_store's own `Index` case (compiler.cr) for the
            # full trace of why this needs a DIFFERENT pop order from
            # Op::SetIndex, not just a rename: this opcode's actual
            # stack shape is `[value, target, index]` (value pushed
            # FIRST, by the caller, before target/index) — the reverse
            # of Op::SetIndex's `[target, index, value]`.
            idx = pop
            target = pop
            val = pop
            exec_set_index(target, idx, val)
            @risk_flow_log.record("SetIndexFromValue", [target.label, val.label], target.label, f.line)
            push(val)
          when Op::SetAttr
            # `call_method` (this file, above) — not a raw
            # `dispatch_call` — specifically because it drives a
            # script-defined setter to COMPLETION synchronously
            # (isolated @frames/@stack, same technique VM#invoke uses)
            # before this opcode's own next line runs. A raw
            # `dispatch_call` would, for a script-defined setter,
            # just PUSH a new Frame and return a sentinel — correct
            # for Op::Call itself (the surrounding execute loop picks
            # the pushed frame up next), but wrong here: this opcode
            # needs the setter's real return value in hand immediately
            # so it can be DISCARDED, in favor of pushing `val` back
            # instead — matching every other Set* opcode's contract
            # (assignment's own value is what was assigned, never
            # whatever a called setter method itself returns).
            sym = chunk.consts[inst.c].as_sym
            val = pop
            recv = pop
            call_method(recv, sym.name, [val], f.filename, f.line)
            @risk_flow_log.record("SetAttr", [recv.label, val.label], val.label, f.line)
            push(val)

            # --- Calls ----------------------------------------------------------
          when Op::SetBlock
            v = pop
            @current_block = v.proc? ? v.as_proc.as(ScriptProc) : nil
            # Snapshot NOW, while `f` is still the block literal's own
            # creation-site frame — Op::Call (which consumes this)
            # happens immediately after, still within the same frame,
            # but by the time a later Op::Yield fires (possibly deep
            # inside the callee), `f` will have moved on entirely.
            # Chained with f's OWN outer_locals (not just f.locals
            # alone) so a block attached two-or-more scopes deep still
            # reaches everything an ordinary variable reference at
            # this point could see — same fix as Op::MakeProc's
            # lambda-capture case just above, same reason (found
            # 2026-08-10, SCOPE.md's "Closures / block scoping" entry).
            @current_block_locals = @current_block ? [f.locals] + (f.outer_locals || [] of Array(Value)) : nil
          when Op::SetKwargNames
            # Same "take the last N, pop them, read in push order"
            # idiom as Op::MakeHash's pairs — @stack.last(n) returns
            # them oldest-pushed-first, so pairs.each_slice(2) lines
            # each (name, value) up correctly without any reversal.
            # Deliberately NOT recorded to @risk_flow_log the way
            # MakeHash's pairs are: this isn't constructing a new
            # composite Value that flows through the script (nothing
            # is pushed back) — each value keeps flowing under its OWN
            # existing label straight into its own param slot in
            # bind_args, exactly as an ordinary positional arg does.
            n = inst.a.to_i * 2
            pairs = @stack.last(n)
            @stack.pop(n) if n > 0
            h = {} of String => Value
            pairs.each_slice(2) { |pair| h[pair[0].as_sym.name] = pair[1] }
            @pending_kwargs = h
          when Op::Call, Op::SafeCall
            sym = chunk.consts[inst.c].as_sym
            argc = inst.a.to_i
            safe = inst.b & 0b01_u16 != 0
            has_receiver = inst.b & 0b10_u16 != 0

            args = @stack.last(argc)
            @stack.pop(argc) if argc > 0

            depth_before = @frames.size
            # `ensure`, not plain sequential code after the call: if
            # dispatch_call RAISES (e.g. check_risk_flow rejecting a
            # kwarg-carrying native call), a bare "reset these after
            # the call" here is never reached — the exception unwinds
            # straight past it, leaving @pending_kwargs (and
            # @current_block/@current_block_locals) stale for
            # whichever Op::Call instruction executes next, ANYWHERE,
            # not just a retry of this same call. Found 2026-08-09:
            # a rejected kwarg-carrying native call inside a
            # script-level `begin/rescue` left @pending_kwargs
            # holding the rejected call's kwargs; the very next
            # Op::Call — compile_rescue_clause_test's own compiled
            # `is_a?` check, used to match the raised exception
            # against the rescue clause's class list — inherited
            # those stale kwargs and got spuriously rejected with
            # R012 for a keyword it never received, since `is_a?`
            # declares no kwarg_names of its own. Not specific to
            # kwargs REACHING a native call at all: the same leak
            # shape is reachable via a script-defined kwarg method's
            # own R011/R012 (VM#bind_args) raising mid-frame-push
            # inside a begin/rescue too — this fix protects both,
            # not just the native path that happened to surface it.
            result = begin
              dispatch_call(sym.name, args, safe, f.filename, inst.line, @current_block, has_receiver,
                blk_outer: @current_block_locals, self_val: f.self_val, kwargs: @pending_kwargs)
            ensure
              @current_block = nil
              @current_block_locals = nil
              @pending_kwargs = nil
            end
            # If dispatch pushed a new ScriptProc frame, do NOT push the
            # sentinel return value — Op::Ret will push the real result.
            push(result) if @frames.size == depth_before
          when Op::Super
            zsuper = inst.b & 0b1_u16 != 0
            argc = inst.a.to_i
            args = @stack.last(argc)
            @stack.pop(argc) if argc > 0

            depth_before = @frames.size
            result = dispatch_super(f, args, f.filename, inst.line, zsuper: zsuper)
            push(result) if @frames.size == depth_before
          when Op::Ret
            result = pop
            # Drain locals back to stack_base
            f.stack_base.upto(@stack.size - 1) { @stack.pop } if @stack.size > f.stack_base
            pop_frame
            push(result) unless @frames.empty?

            # --- Arithmetic -----------------------------------------------------
          when Op::Add    then exec_binary(inst) { |lhs, rhs| exec_add(lhs, rhs, f) }
          when Op::Sub    then exec_binary(inst) { |lhs, rhs| exec_sub(lhs, rhs, f) }
          when Op::Mul    then exec_binary(inst) { |lhs, rhs| ValueOps.op(lhs, rhs, :*, error_raiser(f)) }
          when Op::Div    then exec_binary(inst) { |lhs, rhs| exec_div(lhs, rhs, f) }
          when Op::Mod    then exec_binary(inst) { |lhs, rhs| ValueOps.mod(lhs, rhs, error_raiser(f)) }
          when Op::BitAnd then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :&, error_raiser(f)) }
          when Op::BitOr  then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :|, error_raiser(f)) }
          when Op::Xor    then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :^, error_raiser(f)) }
          when Op::Shl    then exec_binary(inst) { |lhs, rhs| ValueOps.shl(lhs, rhs, error_raiser(f)) }
          when Op::Shr    then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :>>, error_raiser(f)) }
            # --- Comparison -----------------------------------------------------

          when Op::Eq
            b, a = pop, pop
            result = Value.bool(values_equal?(a, b), RiskFlowLabel.join(a.label, b.label))
            @risk_flow_log.record("Eq", [a.label, b.label], result.label, f.line)
            push(result)
          when Op::TripleEq then exec_binary(inst) { |subject, pattern| Value.bool(triple_eq_matches?(pattern, subject)) }
          when Op::Lt       then exec_binary(inst) { |lhs, rhs| Value.bool(compare(lhs, rhs, :<)) }
          when Op::Lte      then exec_binary(inst) { |lhs, rhs| Value.bool(compare(lhs, rhs, :<=)) }
          when Op::Gt       then exec_binary(inst) { |lhs, rhs| Value.bool(compare(lhs, rhs, :>)) }
          when Op::Gte      then exec_binary(inst) { |lhs, rhs| Value.bool(compare(lhs, rhs, :>=)) }
            # --- Unary ----------------------------------------------------------

          when Op::Not
            push(Value.bool(pop.falsy?))
          when Op::Neg
            v = pop
            case
            when v.int?   then push(Value.int(-v.as_int))
            when v.float? then push(Value.float(-v.as_float))
            else               raise script_diagnostic("R005", {"operator" => "-", "type" => describe_value(v)}, f)
            end
          when Op::Pos
            # Mirrors Op::Neg's exact int?/float?/else-raise shape —
            # Adjutant has no per-type +@/-@ overload mechanism (no
            # user-defined class can define its own unary + or -; both
            # are hardcoded VM opcodes, not method dispatch), so unlike
            # real Ruby (where +@ is per-type — String defines it as a
            # real no-op/thaw since 2.3, Array does NOT define it at
            # all and raises NoMethodError) there's no type registry to
            # consult here. Numeric unary + is a genuine no-op in real
            # Ruby too (see docs.ruby-lang.org/en/3.3/syntax/
            # precedence_rdoc.html's own unary-+ example, and Ruby
            # core's own "There is an operator in Ruby that does
            # nothing" framing) — push the SAME value back unchanged
            # rather than reusing Neg's negation, and raise on anything
            # that isn't Integer/Float, matching what Op::Neg already
            # does for consistency across Adjutant's two numeric unary
            # operators.
            v = pop
            case
            when v.int?, v.float? then push(v)
            else                       raise script_diagnostic("R005", {"operator" => "+", "type" => describe_value(v)}, f)
            end
          when Op::BitNot
            v = pop
            raise script_diagnostic("R005", {"operator" => "~", "type" => describe_value(v)}, f) unless v.int?
            push(Value.int(~v.as_int))

            # --- Jumps ----------------------------------------------------------
          when Op::Jump
            f.ip = inst.c.to_i
          when Op::JumpIfFalse
            v = pop
            f.ip = inst.c.to_i if v.falsy?
          when Op::JumpIfTrue
            v = pop
            f.ip = inst.c.to_i if v.truthy?

            # --- Collections ----------------------------------------------------
          when Op::MakeArray
            n = inst.a.to_i
            elements = @stack.last(n).dup
            @stack.pop(n) if n > 0
            joined_label = elements.reduce(nil.as(RiskFlowLabel?)) { |acc, value| RiskFlowLabel.join(acc, value.label) }
            @risk_flow_log.record("MakeArray", elements.map(&.label), joined_label, f.line)
            push(Value.new(LabeledArray.new(elements, joined_label), joined_label))
          when Op::MakeHash
            n = inst.a.to_i * 2
            pairs = @stack.last(n)
            @stack.pop(n) if n > 0
            h = {} of Value => Value
            pairs.each_slice(2) { |pair| h[pair[0]] = pair[1] }
            joined_label = pairs.reduce(nil.as(RiskFlowLabel?)) { |acc, value| RiskFlowLabel.join(acc, value.label) }
            @risk_flow_log.record("MakeHash", pairs.map(&.label), joined_label, f.line)
            push(Value.new(LabeledHash.new(h, joined_label), joined_label))
          when Op::MakeRange
            rend = pop
            rstart = pop
            exclusive = inst.a == 1_u8
            joined_label = RiskFlowLabel.join(rstart.label, rend.label)
            @risk_flow_log.record("MakeRange", [rstart.label, rend.label], joined_label, f.line)
            push(make_range_object(rstart, rend, exclusive, joined_label))
          when Op::MakeRegex
            pattern_val = pop
            push(make_regexp_object(pattern_val.as_string, inst.a.to_i32, pattern_val.label))
          when Op::Concat
            n = inst.a.to_i
            parts = @stack.last(n)
            @stack.pop(n) if n > 0
            str = parts.map { |part| render_to_s(part, f.filename, f.line) }.join
            joined_label = parts.reduce(nil.as(RiskFlowLabel?)) { |acc, part| RiskFlowLabel.join(acc, part.label) }
            @risk_flow_log.record("Concat", parts.map(&.label), joined_label, f.line)
            push(Value.string(str, joined_label))

            # --- Local variables ------------------------------------------------
          when Op::GetLocal
            slot = inst.c.to_i
            push(slot < f.locals.size ? f.locals[slot] : Value.nil_value)
          when Op::SetLocal
            val = pop
            slot = inst.c.to_i
            if slot < f.locals.size
              f.locals[slot] = val
            else
              f.locals << val
            end
            push(val)
          when Op::GetArgc
            push(Value.int(f.argc))
          when Op::HasKwarg
            name = chunk.consts[inst.c].as_sym.name
            push(Value.bool(f.kwarg_names.try(&.includes?(name)) || false))
          when Op::GetOuter
            depth = inst.a.to_i
            slot = inst.c.to_i
            outer = f.outer_locals
            level = outer && depth < outer.size ? outer[depth] : nil
            push(level && slot < level.size ? level[slot] : Value.nil_value)
          when Op::SetOuter
            val = pop
            depth = inst.a.to_i
            slot = inst.c.to_i
            outer = f.outer_locals
            level = outer && depth < outer.size ? outer[depth] : nil
            level[slot] = val if level && slot < level.size
            push(val)
          when Op::MakeProc
            sproc_val = chunk.consts[inst.c]
            if inst.a == 1_u8
              # Snapshot NOW, while `f` is still the lambda literal's
              # own creation-site frame — mirrors Op::SetBlock's
              # snapshot of current_block_locals for ordinary blocks
              # (see Frame#block_outer_locals's comment). Without
              # this, .call later would have nothing correct to fall
              # back on except the CALLING frame's locals, which are
              # only right by coincidence when .call happens to run
              # in the same frame the lambda was written in (see the
              # 2026-07-20 closure-capture bug this fixes,
              # research/IFC_DESIGN.md). Chained with f's OWN
              # outer_locals (not just f.locals alone) so a lambda
              # created two-or-more scopes deep still reaches
              # everything an ordinary variable reference at this
              # point could see — see OuterChain's own comment for why
              # (found 2026-08-10, SCOPE.md's "Closures / block
              # scoping" entry).
              push(make_lambda_object(sproc_val.as_proc, sproc_val.label, [f.locals] + (f.outer_locals || [] of Array(Value)), f.filename, f.line))
            else
              push(sproc_val)
            end
            # --- Class / module ---------------------------------------------
          when Op::GetClass
            push(f.self_val)
          when Op::SetClass
            f.self_val = pop
          when Op::MakeClass
            name_sym = chunk.consts[inst.c].as_sym
            superclass = nil
            if inst.b != Compiler::NO_SUPER
              super_sym = chunk.consts[inst.b].as_sym
              super_val = @globals[super_sym.value]?
              unless super_val && super_val.rclass?
                raise undefined_constant(super_sym.name, f)
              end
              superclass = super_val.as_rclass
            end
            # A script-written `class Foo; end` with no explicit `<
            # Bar` really does inherit from Object in real Ruby — see
            # Interpreter#bootstrap_core_hierarchy. Falls back to nil
            # only when there's no interpreter at all (a bare-VM spec
            # bypassing Interpreter's bootstrap entirely) — a real
            # script always has one.
            superclass ||= @interpreter.try(&.object_class)
            new_cls = RubyClass.new(name_sym.name, superclass, is_module: false)
            new_cls.rclass = @interpreter.try(&.class_class)
            new_cls.lexical_parent = f.self_val.as_rclass?
            push(Value.rclass(new_cls))
          when Op::MakeModule
            name_sym = chunk.consts[inst.c].as_sym
            new_mod = RubyClass.new(name_sym.name, nil, is_module: true)
            # A module's OWN class is Class, not Module — `module M;
            # end; M.class` is Class in real Ruby, the same as any
            # other class/module object. Module (and Class itself) are
            # each instances of Class; is_module? is what distinguishes
            # "can this be instantiated with .new" from "is this the
            # class of classes", not rclass.
            new_mod.rclass = @interpreter.try(&.class_class)
            new_mod.lexical_parent = f.self_val.as_rclass?
            push(Value.rclass(new_mod))
          when Op::DefMethod
            proc_val = pop
            name_sym = chunk.consts[inst.c].as_sym
            # `def` always targets self's CLASS — uniform rule, not two
            # special cases: inside a class/module body, self IS the
            # RubyClass directly (define there); anywhere else with a
            # RubyObject self (top-level main, or `def` nested inside
            # another method body — both legal in real Ruby, and both
            # just mean "self at the point this def executes"), target
            # self's OWN rclass instead. This is what makes a
            # top-level `def greet` become a real (private, in real
            # Ruby's terms) method of Object — callable from anywhere,
            # not a special top-level-only table — matching real
            # Ruby's actual `main`/Object relationship rather than a
            # simplification of it.
            owner_rclass = f.self_val.as_rclass?
            owner = owner_rclass || f.self_val.as_robject?.try(&.rclass)
            unless owner
              raise script_diagnostic("R006", {"definition" => "def #{name_sym.name}"}, f)
            end
            proc = proc_val.as_proc
            proc.lexical_scope = owner
            # `is_private: owner_rclass.nil?` — owner came from the
            # RubyObject branch, not the RubyClass one, exactly when
            # this `def` executed with a RubyObject self. `compile_def`
            # (compiler.cr)'s `@def_depth` guard rejects ANY `def`
            # lexically nested inside another `def`/lambda body at
            # COMPILE time (both `def foo` and `def self.foo` — see
            # that guard's own comment), so a RubyObject self reaching
            # this opcode at RUNTIME can only be `main` — the same
            # "only reachable case" precedent `Op::DefSingleton` (a few
            # lines down) already relies on, not a fresh assumption.
            # Confirmed against real `irb`: top-level `def` lands in
            # `Object.private_methods`, unreachable via an explicit
            # receiver from outside `self` (`x.hello`/`Object.hello`
            # both raise `NoMethodError`) even though bare calls and
            # `self.hello` both work — see `find_method_private?`
            # (ruby_class.cr) for the read side and this method's
            # explicit-receiver branch (below) for enforcement.
            owner.define_method(name_sym.value, proc, is_private: owner_rclass.nil?)
            push(Value.nil_value)
          when Op::DefSingleton
            recv = pop
            proc_val = pop
            name_sym = chunk.consts[inst.c].as_sym
            # `recv` (self at the `def self.foo` site) is either a
            # RubyClass (class/module-body case) or a RubyObject
            # (top-level main — the only RubyObject-self case that can
            # reach here at all, as of 2026-07-27). `def self.foo`
            # written inside an INSTANCE method body — where self
            # would be some OTHER RubyObject — is now rejected at
            # COMPILE time instead, before this opcode is ever emitted
            # (see `compile_def`'s nested-def guard in compiler.cr,
            # which also catches the plain-`def` shape of the same
            # problem — see that guard's own comment for the full
            # trace, including why an earlier, narrower version of
            # this check lived here at runtime and why it moved).
            owner = recv.as_rclass? || recv.as_robject?.try(&.rclass)
            unless owner
              raise script_diagnostic("R006", {"definition" => "def self.#{name_sym.name}"}, f)
            end
            proc = proc_val.as_proc
            proc.lexical_scope = owner
            owner.define_singleton_method(name_sym.value, proc)
            push(Value.nil_value)

            # --- Block / yield --------------------------------------------------
          when Op::Yield
            argc = inst.a.to_i
            args = @stack.last(argc)
            @stack.pop(argc) if argc > 0
            blk = f.block
            if blk
              depth_before = @frames.size
              # f.block_outer_locals — NOT f.locals. The block closes
              # over the scope it was WRITTEN in (captured at
              # Op::SetBlock time, on the CALLER's side, before this
              # frame even existed — see Frame#block_outer_locals),
              # not over this frame's own locals, which are almost
              # always a completely unrelated method body.
              result = call_script_proc(blk, args, f.filename, nil, f.block_outer_locals)
              push(result) if @frames.size == depth_before
            else
              raise script_diagnostic("R007", {"method" => f.proc.name}, f)
            end
          when Op::BlockBreak
            val = pop
            # Unwind consecutive block frames, same loop as before —
            # but now also remembering the LAST one popped (the
            # OUTERMOST of this run, i.e. whichever block frame
            # `Op::Yield` pushed directly atop its caller, if this
            # chain traces back to a yield at all — see below).
            last_popped_proc = nil.as(ScriptProc?)
            while !@frames.empty? && @frames.last.proc.is_block?
              sb = @frames.last.stack_base; (@stack.size - sb).times { @stack.pop } if @stack.size > sb
              last_popped_proc = @frames.last.proc
              pop_frame
            end
            if @frames.empty?
              # Landed on nothing — every frame this popped belonged
              # to an ISOLATED array `invoke_internal` swapped in for
              # one `ncc.invoke` call (a native method's block — see
              # BlockBreakSignal's own comment for the full
              # mechanism), which never contains anything but frames
              # from that one call. Raise past it; invoke_internal's
              # `ensure` restores the OUTER @frames/@stack regardless
              # of raise-vs-return, so no manual restoration is needed
              # here — caught at the nearest enclosing `call_native`.
              raise BlockBreakSignal.new(val)
            elsif last_popped_proc && @frames.last.block == last_popped_proc
              # Landed on the frame that ACTUALLY yielded to this
              # exact block chain — `Frame#block` is precisely what
              # `Op::Yield` itself reads to find the block to invoke
              # (`blk = f.block`), so this equality check is genuinely
              # "is this the method call break should end," not a
              # heuristic. Real Ruby: `break` inside a yielded-to
              # block ends the WHOLE calling method's own call
              # immediately, not just `yield`'s own expression — so
              # terminate this landed frame too, exactly like
              # Op::Ret's own logic (drain to its stack_base, pop it,
              # push the value for whatever's now on top instead of
              # resuming this frame's own execution past the `yield`
              # site at all).
              landed = @frames.last
              (@stack.size - landed.stack_base).times { @stack.pop } if @stack.size > landed.stack_base
              pop_frame
              push(val) unless @frames.empty?
            else
              # Landed on a real frame that did NOT yield to this
              # chain — a genuinely bare `break` with no enclosing
              # loop OR block at all (top-level, or inside an
              # ordinary method reached some other way — `is_block?`
              # was false from the very start, so the loop above
              # never popped anything and `last_popped_proc` stayed
              # nil). Real Ruby raises LocalJumpError here; Adjutant
              # doesn't yet (a separate, pre-existing, still-open gap
              # — see SCOPE.md). Keeping the ORIGINAL behavior —
              # pushing the value and continuing — rather than
              # guessing at a case this fix isn't targeting.
              push(val)
            end

            # --- Exception handling ---------------------------------------
          when Op::Try
            raise internal_diagnostic("I002", {"target" => "Try"}, f) if inst.c == Chunk::NO_TARGET
            f.handlers.push(HandlerEntry.new(rescue_ip: inst.c.to_i))
          when Op::SetEnsure
            raise internal_diagnostic("I002", {"target" => "SetEnsure"}, f) if inst.c == Chunk::NO_TARGET
            if inst.b == 1_u16
              # Same construct as the immediately-preceding Try — add
              # the ensure target to the entry it just pushed, rather
              # than pushing a second entry for one construct.
              if top = f.handlers.last?
                top.ensure_ip = inst.c.to_i
              end
            else
              f.handlers.push(HandlerEntry.new(ensure_ip: inst.c.to_i))
            end
          when Op::EndTry
            clear_rescue_portion(f)
          when Op::EnterEnsure
            # Consumes this frame's pending handler entry entirely,
            # whether reached via normal fallthrough (rescue matched,
            # mismatched-then-rethrown-and-refound, or no error at
            # all) or via the unwind loop jumping in on error — the
            # single place an entry is fully removed, so it can't go
            # stale for a later, unrelated error.
            f.handlers.pop?
          when Op::EndEnsure
            if pending = @pending_reraise
              @pending_reraise = nil
              raise RuntimeError.new(error_message(pending), f, error_value: pending)
            end
          when Op::Throw
            val = pop
            msg = val.string? ? val.as_string : val.to_s
            raise runtime_error(msg, f)
          when Op::Reraise
            val = pop
            raise RuntimeError.new(error_message(val), f, error_value: val)
          when Op::PushError
            # Push the error caught by the nearest enclosing rescue —
            # a typed RubyObject when available (see RuntimeError#error_value),
            # else a plain string.
            push(@last_error)
          when Op::Retry
            # Jump back to start of begin body — stub
            f.ip = 0
            # --- Misc -----------------------------------------------------------

          when Op::MultiUnpack
            tc = inst.a.to_i
            vc = inst.b.to_i
            values = @stack.last(vc)
            @stack.pop(vc) if vc > 0
            # Real Ruby implicitly splats a single Array-valued RHS
            # across multiple targets (`a, b = some_array`) — distinct
            # from the vc > 1 case (`a, b = 1, 2`), where each value
            # was already pushed separately by the compiler and is
            # used as-is, matching Ruby's own asymmetry here (`a, b =
            # [1, 2]` splats; `a, b = [1, 2], 3` does not).
            values = values[0].as_array.to_a if vc == 1 && tc > 1 && values[0].array?
            # Pad or truncate to target count
            padded = Array(Value).new(tc) { |i| i < values.size ? values[i] : Value.nil_value }
            padded.each { |value| push(value) }
          when Op::GetMethodName
            push(Value.string(f.proc.name))
          else
            raise internal_diagnostic("I001", {"opcode" => inst.op.to_s}, f)
          end
        rescue ex : RuntimeError
          # Clear any stale pending re-raise up front: a genuinely new
          # error is starting its own unwind, so whatever was pending
          # from a previous episode (e.g. an ensure body that itself
          # raised, superseding what it was about to re-raise) must
          # not leak forward into this one.
          @pending_reraise = nil

          # Unwind frames looking for an active rescue or ensure
          # handler (the error may originate several calls deep inside
          # the begin body, not just in the frame that was executing).
          # Each frame's handlers stack holds one entry per begin
          # construct, most-recently-entered last — checking rescue_ip
          # before ensure_ip *within the same entry* (not across
          # separate stacks) is what keeps a more-nested construct's
          # handler in front of an outer one's, regardless of which
          # kind either happens to be.
          handler_frame = nil.as(Frame?)
          handler_ip = 0
          entering_ensure = false
          while !@frames.empty?
            candidate = current_frame
            found_on_this_frame = false
            while top = candidate.handlers.last?
              if rip = top.rescue_ip
                handler_frame = candidate
                handler_ip = rip
                # Mirrors Op::EndTry: pops the entry too if it has no
                # linked ensure, since nothing else would.
                clear_rescue_portion(candidate)
                found_on_this_frame = true
                break
              elsif eip = top.ensure_ip
                handler_frame = candidate
                handler_ip = eip
                entering_ensure = true
                # Left as-is — Op::EnterEnsure pops it once reached.
                found_on_this_frame = true
                break
              else
                candidate.handlers.pop # shouldn't happen; defensive
              end
            end
            break if found_on_this_frame
            break if @frames.size == 1 # never pop the outermost frame here
            sb = candidate.stack_base
            (@stack.size - sb).times { @stack.pop } if @stack.size > sb
            pop_frame
          end

          if handler_frame
            while @stack.size > handler_frame.stack_base
              @stack.pop
            end
            if entering_ensure
              # Stash the original error for Op::EndEnsure to resume
              # once the ensure body finishes normally. If the ensure
              # body raises a new error instead, that propagates via
              # the ordinary Crystal-exception path before EndEnsure
              # is ever reached, correctly superseding this one.
              @pending_reraise = ex.error_value || Value.string(ex.message || "RuntimeError")
            else
              @last_error = ex.error_value || Value.string(ex.message || "RuntimeError")
            end
            handler_frame.ip = handler_ip
          else
            raise ex
          end
        end
      end

      @stack.last? || result
    end

    # --- Dispatch -----------------------------------------------------------

    # `protected` — lets a native method (e.g. Range#each, see
    # builtins/range.cr) call a method BY NAME on an arbitrary Value
    # receiver, the same way script code calling `x.foo` would.
    # `invoke` only runs an already-resolved ScriptProc block; this is
    # for the more general "I have a Value and a method name, resolve
    # and call it" case — needed so Range#each can advance via #succ
    # without hardcoding Integer#succ specifically, keeping it generic
    # over any bound type that defines #succ.
    #
    # Real Ruby semantics only since 2026-08-06 — before this, a
    # NATIVE-method target (found via `find_native_method`, a
    # synchronous Crystal call) worked fine, but a SCRIPT-defined
    # method target silently didn't: `dispatch_call`'s robject branch
    # resolves it via `call_script_proc`, which — by design, see that
    # method's own comment — only PUSHES a frame and returns a
    # sentinel (`Value.nil_value`), trusting the caller to be the main
    # `execute` dispatch loop, which naturally continues on to run
    # that pushed frame next. Called synchronously from arbitrary
    # Crystal code instead (as this method's every real caller does —
    # NativeCallContext#call_method, and now VM#compare_via_spaceship
    # for a script `<=>`), that trust doesn't hold: nothing drives the
    # pushed frame forward, so the sentinel gets treated as the real
    # result. Never caught before because call_method's one prior
    # real-world user (Range#each's #succ advance, the very case this
    # method exists for) only ever targets NATIVE methods (Integer
    # registers #succ natively); a script-defined `<=>` was the first
    # caller to actually hit the script-method branch. Same shape as
    # the handoff's own case/when-VM-test gap: complete-looking,
    # never-actually-run code.
    #
    # Fixed the same way `invoke_internal` (above) already solves the
    # identical problem for calling a stored block/proc from native
    # code: isolate `@frames`/`@stack` so a freshly pushed frame is
    # the ONLY thing in them, drive it to completion with a bare
    # `execute` call, then restore the caller's real state. Skipped
    # entirely when `dispatch_call` resolved natively (no frame
    # pushed, `@frames` still empty after it returns) — that path's
    # result is already correct and complete, so re-running `execute`
    # against an empty frame stack would be wasted work at best.
    protected def call_method(recv : Value, name : String, args : Array(Value),
                              filename : String = "<native>", line : Int32 = 0) : Value
      saved_frames = @frames
      saved_stack = @stack
      saved_ins_count = @instruction_count
      saved_cur_block = @current_block
      saved_cur_block_locals = @current_block_locals
      saved_pending_kwargs = @pending_kwargs
      # A sentinel frame, not a truly empty @frames, so `current_frame`
      # (used pervasively for diagnostics, including dispatch_call's
      # own "no local, no native, no global, no builtin" raise) has
      # something real to read even if dispatch_call fails to resolve
      # anything at all — nothing gets pushed in that case, and a
      # genuinely empty @frames would crash `current_frame` before the
      # diagnostic could even be built. Its empty chunk (`f.ip 0 >=
      # chunk.code.size 0`) is what lets `execute`'s own loop
      # terminate cleanly afterward — see below.
      sentinel = Frame.new(SENTINEL_PROC, SENTINEL_CHUNK, 0, filename)
      sentinel.line = line
      @frames = [sentinel]
      @stack = Array(Value).new(256)
      begin
        result = dispatch_call(name, [recv] + args, safe: false, filename: filename, line: line, has_receiver: true)
        # `dispatch_call` either (a) resolved natively/globally and
        # returned the real result directly, with @frames still just
        # [sentinel] — return it as-is — or (b) resolved to a script
        # method via call_script_proc, which — by design, see that
        # method's own comment — only PUSHES a frame and returns a
        # sentinel VALUE (Value.nil_value, an unrelated use of the
        # word from this Frame), trusting the caller to be the main
        # execute loop, which naturally continues on to run it next.
        # Drive it to completion here instead — the same technique
        # invoke_internal (above) uses for calling a stored proc from
        # native code: isolated @frames/@stack so a bare `execute`
        # call only ever sees this one real frame's own bytecode.
        #
        # Op::Ret's `push(result) unless @frames.empty?` will NOT fire
        # when the real frame pops back down to [sentinel] (not
        # empty) — deliberately: that's what lets the sentinel's own
        # empty-chunk break end the loop cleanly next, rather than
        # `execute` trying to run real_frame's caller's bytecode too.
        # The real return value survives anyway, via execute's OTHER,
        # already-existing fallback: `@stack.last? || result` at its
        # very end, where `result` is Op::Ret's own local — exactly
        # the path this already takes for a genuinely value-less
        # sentinel-frame return, no special-casing needed here.
        @frames.size <= 1 ? result : execute
      ensure
        @frames = saved_frames
        @stack = saved_stack
        @instruction_count = saved_ins_count
        @current_block = saved_cur_block
        @current_block_locals = saved_cur_block_locals
        @pending_kwargs = saved_pending_kwargs
      end
    end

    # The display name a native call shows in an error message or a
    # RiskFlowDecisionRequest, for an IMPLICIT-self call specifically.
    # Bare `name`, NOT "ClassName#name" — unlike real explicit-
    # receiver dispatch (obj.foo, where the class qualification is
    # genuinely informative), an implicit-self call looks like a
    # plain function call in the script itself (`delete_file(...)`,
    # not `Object#delete_file(...)`) — the display name should match
    # what's actually in the source, not an internal dispatch detail.
    private def display_name_for_implicit_self(name : String) : String
      name
    end

    # Resolves and invokes a `super` call (Op::Super). Unlike
    # dispatch_call, the method NAME is never carried by the
    # instruction — it's always "whatever method this bytecode is
    # itself running inside," read off the current frame's own proc.
    # Resolution walks self's REAL runtime ancestor chain
    # (RubyClass#ancestors — self/superclass/included-modules,
    # linearized real-Ruby MRO order), starting right AFTER wherever
    # the current proc's own lexical_scope sits in that chain — not a
    # fixed one-hop jump to lexical_scope.superclass, which stopped
    # being correct once `include` existed (a module included
    # directly into lexical_scope sits BETWEEN it and its superclass
    # in the real MRO; see RubyClass#ancestors' own comment and
    # SCOPE.md's git history for the full reasoning). self stays the
    # original receiver throughout — only the starting point of the
    # search moves.
    #
    # A proc with no lexical_scope (a top-level function, or a block)
    # has no ancestor chain to search at all — treated the same as a
    # lookup that starts but finds nothing, below.
    # ameba:disable Metrics/CyclomaticComplexity - two resolution paths (instance vs. the pre-existing singleton fallback), not tangled logic
    private def dispatch_super(f : Frame, args : Array(Value), filename : String, line : Int32,
                               zsuper : Bool = false) : Value
      proc = f.proc
      name = proc.name
      call_args, call_kwargs =
        if zsuper
          zsuper_bindings(f, filename, line)
        else
          {args, nil}
        end
      lex = proc.lexical_scope
      sym_id = lex ? @symbols.lookup(name).try(&.value) : nil

      # STEP 4 of the include-support build-out (see SCOPE.md's git
      # history): `super` can't just jump from `lex` to `lex.superclass`
      # anymore now that `include` exists — a module included directly
      # into `lex` sits BETWEEN it and its superclass in the real MRO
      # (`RubyClass#ancestors`' own comment has the full reasoning), and
      # if the CURRENTLY-EXECUTING method is itself a module's own method
      # (`lex` is a module, not a class), that module has no `superclass`
      # of its own to fall back on at all — only the ACTUAL receiver's
      # full ancestry knows what comes after it. Computed from `self`'s
      # REAL runtime class, not `lex` itself, since `self` may be an
      # instance of a SUBCLASS further down the chain than wherever this
      # method happens to be textually defined (ordinary polymorphism —
      # the search space is self's ancestry, `lex` is just the anchor
      # point within it).
      #
      # `f.self_val.as_robject?` only — deliberately NOT extended to
      # cover `self_val.as_rclass?` (a class-method/singleton `super`,
      # `def self.foo; super; end`) in THIS branch. That's a genuinely
      # separate resolution path — self IS the class object itself,
      # not an instance of it, so the tables to search are the
      # SINGLETON ones (find_singleton_method/
      # find_native_singleton_method), not find_method/
      # find_native_method. Handled by the `elsif` below.
      if lex && sym_id && (obj = f.self_val.as_robject?)
        chain = obj.rclass.ancestors
        idx = chain.index(lex)
        if idx
          chain[(idx + 1)..].each do |candidate|
            if method = candidate.methods[sym_id]?
              return call_script_method(method, call_args, call_kwargs, f, filename)
            end
            if native = candidate.native_methods[sym_id]?
              return call_super_native(native, call_args, call_kwargs, f, filename, line, candidate, name)
            end
          end
        end
      elsif lex && sym_id && (self_cls = f.self_val.as_rclass?)
        # STEP 5 of the extend-support build-out (see SCOPE.md's git
        # history): previously a fixed one-hop jump to `lex.superclass`
        # — correct as far as it went before `extend` existed (Step 1
        # of this build-out already fixed WHICH tables get searched;
        # this step fixes WHERE the search starts and how far it
        # goes). Now mirrors the instance-method branch above exactly,
        # on the singleton side: computed from self's REAL runtime
        # class (`self_cls`, not `lex` — same polymorphism reasoning
        # as the instance branch), searching everything AFTER `lex`'s
        # own position in `self_cls.singleton_ancestors`. See that
        # method's own comment (ruby_class.cr) for why each entry
        # there carries a Bool: an extended module's own contribution
        # must be checked via its ORDINARY method table, not
        # `singleton_methods` — self and its superclasses need the
        # opposite.
        chain = self_cls.singleton_ancestors
        idx = chain.index { |(c, _)| c == lex }
        if idx
          chain[(idx + 1)..].each do |(candidate, use_singleton_table)|
            if use_singleton_table
              if method = candidate.singleton_methods[sym_id]?
                return call_script_method(method, call_args, call_kwargs, f, filename)
              end
              if native = candidate.native_singleton_methods[sym_id]?
                return call_super_native(native, call_args, call_kwargs, f, filename, line, candidate, name)
              end
            else
              if method = candidate.methods[sym_id]?
                return call_script_method(method, call_args, call_kwargs, f, filename)
              end
              if native = candidate.native_methods[sym_id]?
                return call_super_native(native, call_args, call_kwargs, f, filename, line, candidate, name)
              end
            end
          end
        end
      end

      # No ancestor defines a method by this name — real Ruby raises
      # NoMethodError ("super: no superclass method '{method}'") here,
      # not NameError (R008's class): the name resolved to a REAL
      # method once, the one `super` is being called FROM, so this
      # isn't "unresolved," it's "resolved, then deliberately looked
      # one level up, and found nothing there."
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R014",
          primary: Span.new(line: line, filename: filename),
          data: {"method" => name}
        ),
        error_class: "NoMethodError"
      )
    end

    # Shared by both branches of dispatch_super above — calling the
    # found SCRIPT method with the current frame's self/block/block-
    # closure-context all forwarded unchanged (only the METHOD LOOKUP
    # moved; self, and everything about the calling frame's own
    # closure state, stays exactly what it already was).
    private def call_script_method(method : ScriptProc, call_args : Array(Value), call_kwargs : Hash(String, Value)?,
                                   f : Frame, filename : String) : Value
      # f.block/f.block_outer_locals implicitly forward the CURRENT
      # method's own block onward, real Ruby's default — super
      # (either form) passes the enclosing method's block along
      # unless a different one is given explicitly. Reusing
      # f.block_outer_locals (not f.locals) matters: it's the closure
      # context the block was ORIGINALLY attached with, at its own
      # creation site, same reuse Op::Yield's own call_script_proc
      # call makes when actually invoking a block — passing f.locals
      # instead would silently rebind the block to the wrong
      # enclosing scope.
      call_script_proc(method, call_args, filename, f.block,
        self_val: f.self_val, block_outer: f.block_outer_locals, kwargs: call_kwargs)
    end

    # Shared by both branches of dispatch_super above — calling a
    # found NATIVE method the same way, `candidate` being whichever
    # ancestor-chain entry (or, in the fallback branch, superclass)
    # actually owns it, purely for the display name.
    private def call_super_native(native : NativeCallable, call_args : Array(Value), call_kwargs : Hash(String, Value)?,
                                  f : Frame, filename : String, line : Int32, candidate : RubyClass, name : String) : Value
      # Native methods read their receiver as args.first by
      # convention (see call_native's other callers in dispatch_call)
      # — super has no receiver on the stack to reuse, so f.self_val
      # is prepended explicitly here.
      call_native(native, [f.self_val] + call_args, filename, line, f.block, "#{candidate.name}##{name}", kwargs: call_kwargs)
    end

    # Builds the (args, kwargs) a bare `super` (zsuper) forwards —
    # the enclosing method's OWN parameters, read at their CURRENT
    # value (Frame#locals, possibly reassigned since the method
    # started), not the originally-passed values. Walks
    # Frame#proc#ast_params in declared order, matching the exact
    # slot layout VM#bind_args filled at call time:
    #
    #   - a plain/default param forwards its current local value as
    #     one positional arg
    #   - a splat param (`*args`) forwards each of its CURRENT
    #     array's elements as separate positional args (real Ruby
    #     re-expands it, it isn't passed on as one array)
    #   - a kwarg param forwards as a keyword argument, not
    #     positional — collected into a separate Hash, same shape
    #     ordinary keyword calls already use
    #
    # A proc with no ast_params (built directly from a Chunk, no AST
    # — see ScriptProc's own doc comment) has nothing to forward;
    # returns empty, same defensive fallback VM#bind_args itself uses
    # in that case.
    private def zsuper_bindings(f : Frame, filename : String, line : Int32) : {Array(Value), Hash(String, Value)?}
      ast_params = f.proc.ast_params
      return {[] of Value, nil} unless ast_params

      args = [] of Value
      kwargs = nil
      ast_params.each_with_index do |param, slot|
        next if param.block_param? # can't occur (U001), skipped defensively
        val = slot < f.locals.size ? f.locals[slot] : Value.nil_value
        if param.splat?
          val.as_array?.try(&.each { |item| args << item })
        elsif param.kwarg?
          kwargs ||= {} of String => Value
          kwargs[param.name] = val
        else
          args << val
        end
      end
      {args, kwargs}
    end

    # Raises R023 (NoMethodError) if the method/native method that
    # `sym_id` just resolved to, on `cls`, is private (see
    # `RubyClass#find_method_private?`/`find_native_method_private?`)
    # AND the call was made with a receiver that isn't the SAME
    # object as `self` at the call site. Object-identity comparison
    # (`same?`), not "was this spelled `self.`" — matches real Ruby's
    # own relaxed rule (confirmed against a real `irb` session:
    # `self.hello(1)` works from inside the frame where `self` IS
    # that object, the exact same dispatch path an explicit `x.hello`
    # from anywhere else takes). Checked here, once, for both the
    # script-method and native-method branches of the explicit-
    # receiver `RubyObject` dispatch path — the only place this
    # matters, since the implicit-self path never has an "other"
    # receiver to compare against at all.
    private def raise_if_private_call(cls : RubyClass, sym_id : Int32, name : String,
                                      recv : Value, self_val : Value?, filename : String, line : Int32,
                                      native : Bool) : Nil
      is_private = native ? cls.find_native_method_private?(sym_id) : cls.find_method_private?(sym_id)
      return unless is_private
      caller_self = self_val.try(&.as_robject?)
      return if caller_self && caller_self.same?(recv.as_robject)
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R023",
          primary: Span.new(line: line, filename: filename),
          data: {"method" => name, "target" => "an instance of #{cls.name}"}
        ),
        error_class: "NoMethodError"
      )
    end

    # Renders `value`'s REAL `to_s` — real method dispatch
    # (`call_method`), not a Crystal-level `Value#to_s` call, for
    # anything that could have a script- or builtin-defined override
    # (`RubyObject`, `LabeledArray`, `LabeledHash`, and — as of
    # 2026-08-18 — a `RubyClass` value WITH a real `def self.to_s`
    # override; see `rclass_override?`'s own comment). True scalars
    # (Nil/Bool/Int64/Float64/String/Sym) keep the existing direct
    # Crystal-level rendering — cheaper, and equivalent regardless:
    # none of those types is reachable from script code for
    # redefinition (`U003` forbids reopening any class, builtins
    # included), so there's no override real dispatch could ever
    # find that this fast path would miss.
    #
    # Deliberately its own small method, not inlined into any one
    # call site — `puts`/`print` (exec_builtin, below) use it too, as
    # of this same step, and all three (plus Op::Concat) are the ones
    # planned to eventually move outside the VM into a native
    # integration API; keeping the actual "get this value's real
    # string" logic in one place, not duplicated across four call
    # sites, is what makes that future move a relocation rather than
    # a rewrite.
    private def render_to_s(value : Value, filename : String, line : Int32) : String
      case
      when value.string? then value.as_string
      when value.int?    then value.as_int.to_s
      when value.float?  then value.as_float.to_s
      when value.bool?   then value.as_bool.to_s
      when value.null?   then ""
      when value.symbol? then value.as_sym.name
      when value.rclass?
        if rclass_override?(value.as_rclass, "to_s")
          call_method(value, "to_s", [] of Value, filename, line).as_string
        else
          value.to_s
        end
      else call_method(value, "to_s", [] of Value, filename, line).as_string
      end
    end

    # Same shape as render_to_s, `inspect` instead. Simpler split than
    # render_to_s's: `Value#inspect` (value.cr) ALREADY correctly
    # handles every true scalar (Nil/String/Sym get their own real
    # branch there — no `Sym#to_s`-includes-a-colon-style workaround
    # needed here, since `Value#inspect`'s own Sym branch already
    # produces the colon-INCLUDING form real Ruby's `Symbol#inspect`
    # wants), so this only needs to intercept the types with a REAL,
    # potentially-overridden `inspect` to dispatch to —
    # `RubyObject`/`LabeledArray`/`LabeledHash` always, `RubyClass`
    # only when it actually HAS an override (`rclass_override?`).
    private def render_inspect(value : Value, filename : String, line : Int32) : String
      if value.robject? || value.array? || value.hash? ||
         (value.rclass? && rclass_override?(value.as_rclass, "inspect"))
        call_method(value, "inspect", [] of Value, filename, line).as_string
      else
        value.inspect
      end
    end

    # Whether `cls` has a REAL singleton override for `name` — checked
    # BEFORE dispatching, not "dispatch and rescue on failure," since
    # a blanket rescue would ALSO swallow a genuine exception a
    # script's own override deliberately raises (real Ruby propagates
    # that; render_to_s/render_inspect must too, not silently fall
    # back to the default rendering instead). No override found means
    # the DEFAULT rendering applies (`value.to_s`/`value.inspect`,
    # unchanged from before this check existed) — real Ruby's own
    # `Class#to_s`/`#inspect` default (the qualified name, no
    # override) doesn't require an actual registered method to exist
    # either; `exec_builtin`'s own universal `"to_s"`/`"inspect"`
    # fallback cases (below) already provide that default via the
    # EXPLICIT-call path, and this mirrors it for the implicit one.
    # `find_singleton_method`/`find_native_singleton_method` — same
    # two tables `respond_to?`'s own check already consults, so a
    # class WITH an override was ALREADY respond_to?-visible before
    # this fix; only the IMPLICIT-rendering gap (this method) was
    # open, not a respond_to? gap for the has-an-override case. A
    # class with NO override remains a known, accepted, narrower
    # respond_to? gap (SCOPE.md's own entry on that) — real Ruby's
    # `Class#to_s` is a genuine inherited `Object` method reachable
    # through the metaclass chain, which Adjutant doesn't model.
    private def rclass_override?(cls : RubyClass, name : String) : Bool
      sym_id = @symbols.lookup(name).try(&.value)
      return false unless sym_id
      !!(cls.find_singleton_method(sym_id) || cls.find_native_singleton_method(sym_id))
    end

    # See NativeCallContext#guard_rendering's own comment for the full
    # reasoning — this is where the actual Set lives and where the
    # `ensure` actually runs, which is the entire point of this being
    # one method instead of a begin/end pair every caller has to
    # bracket correctly themselves.
    def guard_rendering(obj_id : UInt64, cycle_result : String, & : -> String) : String
      return cycle_result if @rendering_ids.includes?(obj_id)
      @rendering_ids << obj_id
      begin
        yield
      ensure
        @rendering_ids.delete(obj_id)
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity - Clear steps, better together
    private def dispatch_call(name : String,
                              args : Array(Value),
                              safe : Bool,
                              filename : String, line : Int32,
                              blk : ScriptProc? = nil,
                              has_receiver : Bool = false,
                              blk_outer : OuterChain? = nil,
                              self_val : Value? = nil,
                              kwargs : Hash(String, Value)? = nil) : Value
      # 1) Safe navigation: skip call if receiver (first arg) is nil
      if safe && !args.empty? && args.first.null?
        return Value.nil_value
      end

      # 1.5) Receiver-based dispatch: instance methods and `.new`, checked
      # ahead of native/global/builtin so a class's own methods win over
      # any same-named global function.
      if has_receiver && !args.empty?
        recv = args.first
        if recv.rclass? && name == "new"
          # kwargs now thread all the way through to a script-defined
          # `initialize` (see construct/construct_object below) —
          # bind_args's existing per-Param machinery (bind_kwarg_param,
          # check_unknown_keywords!) does the real name-matching
          # exactly as it already does for any other method call.
          # `construct` itself still fails loudly (R012) when there's
          # nowhere for a keyword arg to go: native construction whose
          # NativeCallable declares no kwarg_names (call_native's own
          # check_unknown_native_keywords!, same as any other native
          # call — see NativeCallable#kwarg_names) or a class with no
          # `initialize` at all (construct_object's own
          # reject_kwargs!, mirroring the same guard).
          return construct(recv.as_rclass, args[1..], filename, line, blk, kwargs: kwargs)
        end
        if recv.robject?
          cls = recv.as_robject.rclass
          if sym_id = @symbols.lookup(name).try(&.value)
            if method = cls.find_method(sym_id)
              raise_if_private_call(cls, sym_id, name, recv, self_val, filename, line, native: false)
              return call_script_proc(method, args[1..], filename, blk, nil, self_val: recv, block_outer: blk_outer, kwargs: kwargs)
            end
            if native = cls.find_native_method(sym_id)
              raise_if_private_call(cls, sym_id, name, recv, self_val, filename, line, native: true)
              return call_native(native, args, filename, line, blk, "#{cls.name}##{name}", kwargs: kwargs)
            end
          end
        elsif recv.rclass?
          # A RubyClass receiver dispatches to ITS OWN singleton
          # methods (def self.foo / a native singleton method),
          # never to the instance method table — `A.find_method`
          # would resolve methods meant for instances of A, which is
          # simply the wrong table for a call on A itself.
          cls = recv.as_rclass
          if sym_id = @symbols.lookup(name).try(&.value)
            if method = cls.find_singleton_method(sym_id)
              return call_script_proc(method, args[1..], filename, blk, nil, self_val: recv, block_outer: blk_outer, kwargs: kwargs)
            end
            if native = cls.find_native_singleton_method(sym_id)
              return call_native(native, args, filename, line, blk, "#{cls.name}.#{name}", kwargs: kwargs)
            end
          end
        elsif interp = @interpreter
          # Builtin-typed receiver (Integer today; String/Array etc. as
          # they land) — no rclass of its own, resolved via
          # Interpreter#builtin_class_for instead.
          if (cls = interp.builtin_class_for(recv)) && (sym_id = @symbols.lookup(name).try(&.value))
            if native = cls.find_native_method(sym_id)
              return call_native(native, args, filename, line, blk, "#{cls.name}##{name}", kwargs: kwargs)
            end
          end
        end
      end

      # 2) Implicit self: a bare/receiverless call tries self's OWN
      # class first — matching real Ruby's actual method resolution
      # (a bare `greet` inside any body, including top level, tries
      # `self.greet` before anything else). This is what makes a
      # top-level `def greet` reachable via a later bare `greet` call:
      # top-level self is `main` (a RubyObject of class Object — see
      # Interpreter#main), so `def greet` at top level lands in
      # Object#methods (see Op::DefMethod), and THIS step is what
      # finds it again — @globals no longer holds defs at all (see
      # the 2026-07-16 root-scope work; @globals is constants/classes
      # only now). This ALSO now covers what used to be a separate
      # "check native functions registered via interpreter" step:
      # define_native registers into Object's own native_methods
      # table (see Interpreter#define_native), the exact table
      # find_native_method below checks — a genuinely separate step
      # was redundant with this one, and (worse) didn't respect
      # has_receiver AT ALL, so ANY receiver (even one with no
      # inheritance relationship to Object at all — impossible in
      # practice, since every RubyObject's class ultimately descends
      # from Object, but the old step didn't even check that much)
      # could resolve a native function. Note this is NOT the same as
      # matching real Ruby's private-method visibility rule —
      # Adjutant has no public/private/protected modifiers at all, so
      # step 1.5 (explicit-receiver dispatch, above) correctly finds
      # an inherited native/top-level method via a normal
      # find_native_method superclass walk, same as any other
      # inherited method (`Foo.new.some_native_fn` DOES work if Foo <
      # Object, which every script class is by default) — genuinely
      # different from real Ruby, and a real, separate gap (method
      # visibility) this piece doesn't attempt to close.
      unless has_receiver
        if self_val && (sym_id = @symbols.lookup(name).try(&.value))
          if obj = self_val.as_robject?
            # Top-level `include` is NOT a generic Object/Module
            # inheritance relationship — Object does NOT include
            # Module (the real hierarchy runs the other way:
            # `Module < Object`), so `obj.rclass`'s own chain (walked
            # just below) can never reach `Module#include` the way a
            # class/module body's self_rclass branch does. Real
            # Ruby's own `main` object has bespoke singleton behavior
            # for exactly this case (confirmed against a real `irb`
            # session — `main` mutates `Object`'s ancestor chain
            # directly on `include`, publicly, matching the SAME
            # bare/declarative shape `U018` already treats as safe
            # for a class/module body — see SCOPE.md's "Object model"
            # group and UNSUPPORTED.md's U018 entry for the full
            # reasoning). Checked BEFORE the ordinary find_method/
            # find_native_method lookups below, matching real Ruby's
            # own singleton-methods-before-class-chain resolution
            # order: a top-level `def include` should NOT shadow this
            # (real `main.singleton_methods` lists `include` as a
            # pre-existing singleton method, taking precedence over
            # anything `def` could add to Object itself). Restricted
            # to `main` specifically, not every RubyObject self —
            # same "only reachable case" shape Op::DefSingleton's own
            # comment already established for a RubyObject self
            # reaching that opcode at all.
            #
            # `extend` is DELIBERATELY not handled here — confirmed
            # against a real `irb` session that top-level `extend`
            # writes to a genuine per-object singleton class on
            # `main` alone (untouched Object ancestors, unaffected
            # sibling instances, unaffected `Object.foo`), which
            # `RubyObject` has no storage for at all today. Left
            # unhandled on purpose: falls through to the ordinary
            # undefined-method path below, then to U018's
            # EXCLUDED_METHODS catch, same as before this change —
            # a clear, already-existing "not supported" outcome
            # rather than a silently wrong one. Tracked as its own,
            # separate SCOPE.md item once scoped.
            if name == "include" && !args.empty? &&
               (interp = @interpreter) && obj.same?(interp.main) &&
               (mod = args.first.as_rclass?)
              obj.rclass.include_module(mod)
              return self_val
            end

            # self is an ordinary object (main at top level, or any
            # instance inside its own method body) — its OWN class's
            # instance-method chain is exactly what a bare call means
            # here, same table an explicit `self.foo`/`obj.foo` would
            # use.
            cls = obj.rclass
            if method = cls.find_method(sym_id)
              return call_script_proc(method, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs)
            end
            if native = cls.find_native_method(sym_id)
              return call_native(native, args, filename, line, blk, display_name_for_implicit_self(name), kwargs: kwargs)
            end
          elsif self_rclass = self_val.as_rclass?
            # self IS a class/module object (inside a class/module
            # body). Two genuinely different lookups here, not one:
            #
            # 1) self_rclass's OWN singleton tables — `def self.foo`
            #    called bare from elsewhere in the same body (these
            #    are methods usable ON this class/module object
            #    itself, exactly what implicit self means here).
            #
            # 2) self_rclass.rclass's (Module's, for a `module M`
            #    body — Class's, for a `class Foo` body) instance-
            #    method CHAIN, walked up to Object — this is how a
            #    bare receiverless native call (`puts`, or any
            #    define_native function) resolves inside a class/
            #    module body in real Ruby: M is itself an INSTANCE of
            #    Module, and Module < Object (see
            #    bootstrap_core_hierarchy), so M can call anything
            #    Object provides, the same way any other object can.
            #    A module has NO superclass of its own to walk (only
            #    classes do) — this chain is genuinely different from
            #    that, and is what was MISSING before, causing a
            #    regression: a module body couldn't reach ANY native
            #    function (assert_not_nil, puts, ...) at all.
            #
            # self_rclass.find_method/.find_native_method (self's own
            # INSTANCE tables — i.e. what M.new's instances, or
            # things that `include M`, would see) are deliberately
            # NOT checked here — those mean something different
            # (methods available on instances OF this class), not
            # methods usable on the class object itself.
            if singleton = self_rclass.find_singleton_method(sym_id)
              return call_script_proc(singleton, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs)
            end
            if native_singleton = self_rclass.find_native_singleton_method(sym_id)
              return call_native(native_singleton, args, filename, line, blk, display_name_for_implicit_self(name), kwargs: kwargs)
            end
            if meta = self_rclass.rclass
              if method = meta.find_method(sym_id)
                return call_script_proc(method, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs)
              end
              if native = meta.find_native_method(sym_id)
                return call_native(native, args, filename, line, blk, display_name_for_implicit_self(name), kwargs: kwargs)
              end
            end
          end
        end
      end

      # 3) Check globals for a ScriptProc — legacy fallback only.
      # @globals no longer holds top-level defs (step 2 above finds
      # those, via Object#methods) or top-level plain variables (real
      # locals since the 2026-07-15 scoping fix); nothing in a
      # currently-parseable script writes a ScriptProc into @globals
      # anymore. Kept as a defensive fallback rather than removed
      # outright, same reasoning as emit_store_name's own
      # SetGlobal fallback. self_val threaded through for the same
      # reason, even though this path is dead in practice.
      sym = @symbols.lookup(name)
      if sym
        gval = @globals[sym.value]?
        if gval && gval.proc?
          sproc = gval.as_proc.as(ScriptProc)
          return call_script_proc(sproc, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs)
        end
      end

      # 4) Built-in fallback operations
      if result = exec_builtin(name, args, filename, line, blk, kwargs: kwargs)
        return result
      end

      # Nothing resolved. Before reporting the name as merely undefined,
      # check whether it names a construct Adjutant deliberately
      # excludes — the difference matters, because "undefined" invites
      # the reader (often an LLM) to retry with a variation, and every
      # variation will fail identically.
      #
      # Checked HERE, after resolution, not at compile time: a script
      # may define its own `send`, and rejecting the name outright would
      # break that. Reaching this point means the name resolved to
      # nothing, so the script meant Ruby's construct.
      if code = ErrorCatalog::EXCLUDED_METHODS[name]?
        raise excluded_construct(code, name, filename, line)
      end

      # No local, no native, no global proc, no builtin — this is an
      # unresolved bare identifier/method name. Real Ruby raises
      # NameError here (undefined local variable or method), so this
      # is script-catchable via `rescue NameError` (or `rescue`, since
      # NameError < StandardError) rather than silently returning nil.
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R008",
          primary: Span.new(line: line, filename: filename),
          data: {"name" => name}
        ),
        current_frame,
        error_class: "NameError"
      )
    end

    # Invoke a NativeCallable, wrapping any Crystal exception as a
    # runtime error. Shared by receiver-dispatched native methods
    # (RubyClass#find_native_method) and top-level native functions
    # (Interpreter#native_callable) — same calling convention, same
    # error-wrapping contract.
    #
    # Before the call itself, runs the risk flow check (see
    # research/IFC_DESIGN.md's enforcement design notes): if any
    # argument's label carries a ProvenanceTag whose sensitivity,
    # combined with one of `native.risk.tags`, resolves to
    # RiskFlowAction::Reject or ::Ask via `@risk_flow_policy`, the call
    # does not proceed silently — Reject (or an Ask resolved to Reject
    # by `@on_risk_flow_decision`) raises a script-catchable
    # RiskFlowRejectedError (see raise_risk_flow_rejected); Ask
    # resolved to Allow proceeds normally.
    private def call_native(native : NativeCallable, args : Array(Value),
                            filename : String, line : Int32, blk : ScriptProc?, name : String,
                            kwargs : Hash(String, Value)? = nil) : Value
      check_unknown_native_keywords!(kwargs, native.kwarg_names, name, filename, line)
      check_risk_flow(native, args, kwargs, name, filename, line)
      NativeFunctionCall.new(self, native, filename, line, name, kwargs).call(args, blk)
    rescue ex : BlockBreakSignal
      # `break` inside the block THIS call received (however many
      # times, or however deep inside its own native Crystal code,
      # `ncc.invoke` was called before it happened) — matching real
      # Ruby, the break's value becomes this call's own overall
      # result, ending it early. The native method itself (range.cr,
      # array.cr, ...) needed no change at all — this is the ONE
      # place every native call funnels through, so it's also the one
      # place that needs to know break happened. See
      # BlockBreakSignal's own comment for why this specific spot is
      # correct even for nested native calls with blocks of their own.
      ex.value
    rescue ex : Legate::FatalSignal
      # A fatal Legate condition (Denied/Exhausted/Aborted — LEGATE.md
      # §9.2), raised by a Legate verb somewhere inside this native
      # call (however deeply nested). Deliberately re-raised UNCHANGED,
      # not wrapped — the entire point of FatalSignal being a plain
      # Exception rather than a RuntimeError is that it must reach
      # past BOTH this method's own `rescue ex` catch-all below (which
      # would otherwise flatten it into a script-catchable N001
      # diagnostic, exactly like any other unexpected native failure)
      # AND the dispatch loop's per-instruction `rescue ex :
      # RuntimeError` (execute, above) — so no `rescue` clause of any
      # class, INCLUDING `rescue Exception`, ever gets a chance to
      # match it. This explicit clause exists only so the catch-all
      # below doesn't accidentally swallow it first; it does no
      # transformation of its own. See FatalSignal's own comment
      # (legate/exceptions.cr) for the full reasoning.
      raise ex
    rescue ex : RuntimeError
      raise ex
    rescue ex
      # Deliberately its own letter rather than an R code: Adjutant does
      # not know whether the script passed something bad or the host's
      # own function is broken, and an R code would imply it had decided.
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "N001",
          primary: Span.new(line: line, filename: filename),
          data: {
            "function" => name,
            "message"  => ex.message || ex.class.to_s,
          }
        ),
        current_frame,
        cause: ex
      )
    end

    # The risk flow check itself — see call_native's doc comment. A
    # no-op (cheap: one empty-tags check, no allocation) for the
    # overwhelming majority of native calls, which either have no
    # RiskTag at all (RiskProfile.none) or receive no labeled arguments.
    private def check_risk_flow(native : NativeCallable, args : Array(Value), kwargs : Hash(String, Value)?,
                                name : String, filename : String, line : Int32) : Nil
      return if native.risk.tags.empty?
      kwarg_values = kwargs.try(&.values)
      labeled_args = args.any?(&.label)
      labeled_kwargs = kwarg_values.try(&.any?(&.label)) || false
      return unless labeled_args || labeled_kwargs

      matches = [] of RiskFlowMatch
      native.risk.tags.each do |tag|
        # kwargs are folded in here (not just `args`) so a labeled
        # value reaching a risk-tagged native call via a keyword
        # argument gets the exact same enforcement a positional
        # argument already did — before native kwargs existed at all,
        # this was moot (reject_kwargs! fired first); now that a
        # native callable can legitimately declare kwarg_names, a
        # value in a keyword slot is just as real a risk-flow input as
        # one in `args`, and skipping it here would silently bypass
        # enforcement for exactly the calls this feature exists to
        # support.
        (args + (kwarg_values || [] of Value)).each do |arg|
          label = arg.label
          next unless label
          label.tags.each do |provenance_tag|
            action, rule = @risk_flow_policy.action_for(tag, provenance_tag.sensitivity)
            next if action.allow?
            matches << RiskFlowMatch.new(action, rule, provenance_tag)
          end
        end
      end
      return if matches.empty?

      resolve_risk_flow_matches(matches, name, native.risk, filename, line)
    end

    # Explicit counterpart to check_risk_flow's automatic, label-driven
    # check — see NativeFunctionCall#declare_sensitivity (the public
    # entry point native functions actually call) for why this exists:
    # a native function whose own argument is the risky subject (a path
    # being deleted, a URL being posted to) may need to consult policy
    # on that argument's literal content directly, not only rely on a
    # label some upstream call may or may not have already attached.
    # `sensitivity` lets a native function that already knows the
    # sensitivity (e.g. it just computed it) skip the lookup; when nil,
    # this method performs the lookup itself via `sensitivity_for`.
    def declare_sensitivity(tag : RiskTag, kind : ProvenanceKind, origin : String, name : String,
                            filename : String, line : Int32, sensitivity : Sensitivity? = nil) : Nil
      resolved_sensitivity = sensitivity || @risk_flow_policy.sensitivity_for(kind, origin)
      return if resolved_sensitivity.none?

      action, rule = @risk_flow_policy.action_for(tag, resolved_sensitivity)
      return if action.allow?

      provenance_tag = ProvenanceTag.new(kind, origin, resolved_sensitivity)
      matches = [RiskFlowMatch.new(action, rule, provenance_tag)]
      risk = RiskProfile.new(tags: Set{tag})
      resolve_risk_flow_matches(matches, name, risk, filename, line)
    end

    # Shared by check_risk_flow (automatic, label-driven) and
    # declare_sensitivity (explicit, native-function-driven): given a
    # non-empty list of already-built RiskFlowMatches, sorts them
    # worst-first, builds the RiskFlowDecisionRequest, and resolves it —
    # Reject (or reject_all, or an Ask resolved to Reject via
    # @on_risk_flow_decision) raises; Allow (directly, or via a
    # callback's answer to Ask) returns normally.
    private def resolve_risk_flow_matches(matches : Array(RiskFlowMatch), name : String, risk : RiskProfile,
                                          filename : String, line : Int32) : Nil
      # Worst-first: RiskFlowAction (Reject > Ask), then Sensitivity
      # (High > Elevated), stable beyond that — see
      # RiskFlowDecisionRequest#matches's doc comment.
      matches = matches.sort_by { |match| {-match.action.value, -match.tag.sensitivity.value} }

      request = RiskFlowDecisionRequest.new(name, risk, matches, filename, line)

      worst_action = matches.first.action
      if worst_action.reject?
        raise_risk_flow_rejected(request, filename, line)
      else
        # Ask: every path through here requires a real decision — no
        # implicit fallback (see Interpreter's required
        # on_risk_flow_decision param and research/IFC_DESIGN.md).
        decision = @on_risk_flow_decision.call(request)
        raise_risk_flow_rejected(request, filename, line) if decision.reject?
      end
    end

    # Raises a script-catchable RiskFlowRejectedError — following the
    # same one-Crystal-exception-type pattern every other script-raised
    # error uses (see Op::raise's "raise" handler above and
    # runtime_error/make_error_object): the Crystal-level exception is
    # always RuntimeError, script-visible identity comes from
    # error_value (a RubyObject of the bootstrapped RiskFlowRejectedError
    # class), not from a separate Crystal exception hierarchy — needed
    # because the dispatch loop's rescue-and-unwind machinery only
    # catches `RuntimeError` specifically (see execute's `rescue ex :
    # RuntimeError` clause).
    private def raise_risk_flow_rejected(request : RiskFlowDecisionRequest, filename : String, line : Int32) : NoReturn
      first = request.matches.first
      reason = first.rule.try { |rule| "#{rule.tag} (#{first.tag})" } || "reject_all policy (#{first.tag})"
      diag = Diagnostic.new(
        code: "F001",
        primary: Span.new(line: line, filename: filename),
        data: {"call" => request.call_name, "reason" => reason}
      )
      # The script-visible class stays RiskFlowRejectedError: scripts are
      # documented as able to `rescue` it, and that contract is
      # independent of how the refusal is reported to the host.
      cls = builtin_class_by_name("RiskFlowRejectedError")
      err_val = cls ? make_error_object(cls, diag.summary) : Value.string(diag.summary)
      raise RuntimeError.new(diag, filename, line, error_value: err_val)
    end

    # `Foo.new(args)` — dispatches to a native singleton `new` if the
    # class (or an ancestor) registered one via
    # RubyClass#define_native_singleton_method, otherwise falls back
    # to the generic script-`initialize` path. A native `new` is
    # responsible for its own allocation (typically a RubyObject
    # subclass carrying real state) and return value; the generic path
    # cannot express that, since it always allocates a bare
    # RubyObject.
    private def construct(cls : RubyClass, args : Array(Value), filename : String, line : Int32, blk : ScriptProc?,
                          kwargs : Hash(String, Value)? = nil) : Value
      raise script_diagnostic("R009", {"module" => cls.name}, current_frame) if cls.is_module?
      if cls.uninstantiable?
        # `Class.new`/`Module.new` — see RubyClass#uninstantiable? and
        # Interpreter#bootstrap_core_hierarchy for why these two
        # specifically are marked this way (not the same thing as
        # `is_module?` above, which is about ordinary `module Foo; end`
        # definitions). Before this guard, both fell through to
        # construct_object below and silently succeeded, producing a
        # bare, non-functional RubyObject — see UNSUPPORTED.md, U002.
        raise runtime_diagnostic(
          Diagnostic.new(
            code: "U002",
            primary: frame_span(current_frame),
            data: {"class" => cls.name}
          )
        )
      end
      if sym_id = @symbols.lookup("new").try(&.value)
        if native_new = cls.find_native_singleton_method(sym_id)
          # A native `new` is just another NativeCallable — kwargs
          # thread straight through to the same call_native (and its
          # check_unknown_native_keywords!/check_risk_flow) every other
          # native call already goes through. A native `new` that
          # wants keyword args (e.g. `Config.new(retries:, timeout:)`
          # backed by Crystal) declares them via `kwarg_names` on
          # define_native_singleton_method, same as an instance native
          # method would; one that declares none gets the same R012
          # any other kwarg-less native call gets.
          return call_native(native_new, [Value.rclass(cls)] + args, filename, line, blk, "#{cls.name}.new", kwargs: kwargs)
        end
      end
      construct_object(cls, args, filename, line, kwargs)
    end

    # The generic construction path: allocates a bare RubyObject and,
    # if the class (or an ancestor) defines `initialize`, runs it
    # synchronously via `invoke` so its return value can be discarded
    # and the object returned regardless of what `initialize` itself
    # returns.
    private def construct_object(cls : RubyClass, args : Array(Value), filename : String, line : Int32,
                                 kwargs : Hash(String, Value)? = nil) : Value
      obj_val = Value.robject(RubyObject.new(cls))
      if sym_id = @symbols.lookup("initialize").try(&.value)
        if init = cls.find_method(sym_id)
          invoke(init, args, self_val: obj_val, kwargs: kwargs)
          return obj_val
        end
      end
      # No user-defined `initialize` to bind keyword args against —
      # unlike bind_args's check_unknown_keywords! (which raises R012
      # by NAME once it knows the declared param set), there's no
      # Param list here at all, same gap call_native's own
      # reject_kwargs! exists for. Without this, kwargs would be
      # silently discarded instead of failing loudly.
      reject_kwargs!(kwargs, "#{cls.name}.new", filename, line)
      obj_val
    end

    # Call a ScriptProc, binding arguments to param slots and optionally
    # passing a block and outer locals for closure capture.
    # Does NOT call execute recursively — pushes the frame and returns a
    # sentinel. The outer execute loop continues with the new frame, and
    # Op::Ret restores the caller frame automatically.
    #
    # `self_val` binds the new frame's `self`. If omitted, self is
    # inherited from the calling frame — correct for plain nested calls
    # and for blocks, which keep the enclosing method's self.
    #
    # `lexical_scope` normally comes from the proc itself (methods get a
    # fixed scope at def-time, opaque to the caller). `lexical_override`
    # forces `lexical_scope` regardless of `proc.lexical_scope` — used
    # only by `invoke`, which has already computed the correct value
    # before resetting the frame stack.
    # `blk`/`block_outer` travel together: `blk` is the block PASSED TO
    # `proc` (available inside `proc`'s body as the implicit `yield`
    # target), `block_outer` is the locals array active at the moment
    # `blk` was attached to this call (see Op::SetBlock) — carried on
    # the new frame so Op::Yield, whenever it eventually fires inside
    # `proc`'s body, can correctly close `blk` over ITS creation site
    # rather than over `proc`'s own locals.
    private def call_script_proc(proc : ScriptProc,
                                 args : Array(Value),
                                 filename : String,
                                 blk : ScriptProc? = nil,
                                 outer : OuterChain? = nil,
                                 self_val : Value? = nil,
                                 lexical_scope : RubyClass? = nil,
                                 lexical_override : Bool = false,
                                 block_outer : OuterChain? = nil,
                                 kwargs : Hash(String, Value)? = nil) : Value
      base = @stack.size
      inherited_self = self_val || (@frames.empty? ? Value.nil_value : current_frame.self_val)
      effective_lexical = if lexical_override
                            lexical_scope
                          else
                            proc.lexical_scope || (@frames.empty? ? nil : current_frame.lexical_scope)
                          end
      # Captured before push_frame changes what current_frame means —
      # this is the CALLER's line (where the call itself happened),
      # which is what bind_args should log a splat-collection
      # RiskFlowEvent against; the freshly pushed callee frame's own
      # `line` is still 0 at this point (only execute's dispatch loop
      # advances it, once the callee's first instruction runs).
      caller_line = @frames.empty? ? 0 : current_frame.line
      frame = push_frame(proc, filename, block: blk, stack_base: base, outer: outer, self_val: inherited_self,
        lexical_scope: effective_lexical, block_outer_locals: block_outer, argc: args.size)
      frame.kwarg_names = kwargs.keys.to_set if kwargs
      bind_args(frame, proc, args, caller_line, kwargs)
      Value.nil_value # sentinel; Op::Ret will push the real return value
    end

    # Binds `args` (the caller's actual positional Values) and
    # `kwargs` (the caller's actual keyword Values, by name) into
    # `frame.locals`, slot-by-slot in declared order. Three shapes,
    # only the first two of which the plain index-copy this replaced
    # ever understood:
    #
    #   - A splat param (`Param#splat?`) absorbs every remaining
    #     positional arg once the params before it are satisfied, as
    #     an Array — not a single Value at its slot, which is what
    #     plain index-copy did (see SCOPE.md's Must Fix entry, now
    #     resolved). At most one splat is expected per param list (the
    #     parser doesn't reject a second one, but nothing upstream of
    #     here does either — not this method's job to validate shape
    #     the parser should have).
    #   - A param with `Param#default` and no matching positional arg
    #     is deliberately left AT `nil_value` here, not filled — see
    #     Compiler#emit_default_prologue, which runs immediately after
    #     this method returns (as the first real instructions of
    #     `frame.chunk`) and evaluates the default expression itself.
    #     Evaluating a default requires running compiled bytecode (it
    #     can reference earlier params, e.g. `def f(a, b = a + 1)`),
    #     which this method — plain Crystal, no access to `execute` —
    #     cannot do; only the compiled prologue can. `Op::GetArgc`
    #     (see that opcode's comment) is how the prologue tells
    #     "omitted" apart from "explicitly passed nil," since a Value
    #     already sitting at nil_value doesn't say which happened.
    #   - A kwarg param (`Param#kwarg?`) is looked up in `kwargs` BY
    #     NAME, never by position — it never touches `pos` at all, so
    #     it can't accidentally consume a positional arg meant for a
    #     later param, and a positional arg can't accidentally satisfy
    #     it either. Present → bound directly, immediately, right
    #     here (no bytecode needed — presence is a plain Hash lookup,
    #     unlike evaluating a default expression). Absent with a
    #     default → left at nil_value for the compiled prologue, same
    #     deferral as an ordinary default and for the same reason,
    #     just tested by name (`Op::HasKwarg`) instead of by count.
    #     Absent with NO default → raised on immediately, right here
    #     (R011) — nothing to defer, since there's no expression to
    #     run, just a fixed fact already known: the caller was
    #     supposed to name it and didn't.
    #
    # A plain required param (no default, no splat, no kwarg) still
    # binds exactly as before: positional-index copy, silently absent
    # (nil_value) if the caller passed too few — Adjutant has never
    # arity-checked positional calls, and this is not the place that
    # starts (a kwarg's stricter treatment above is deliberate, not an
    # inconsistency — real Ruby is exactly this asymmetric too: a
    # missing positional arg is quietly nil-able in loose style, but a
    # keyword contract, once declared, is enforced).
    #
    # `proc.ast_params` is nil only for the placeholder ScriptProcs
    # RiskWalker constructs for static analysis (never executed, see
    # that file's own comment) — every real, callable proc (from
    # Compiler#compile_def/#compile_lambda/#compile_call's block
    # literal, or the synthetic no-default/no-splat Params
    # Compiler#compile_for builds for its `each`-block desugar) always
    # carries it, so the plain-positional fallback below exists for
    # completeness, not because a live call path hits it.
    private def bind_args(frame : Frame, proc : ScriptProc, args : Array(Value), caller_line : Int32,
                          kwargs : Hash(String, Value)? = nil) : Nil
      ast_params = proc.ast_params
      unless ast_params
        args.each_with_index { |arg, i| frame.locals[i] = arg if i < frame.locals.size }
        return
      end
      pos = 0 # index into `args` — advances only for non-splat, non-kwarg params
      declared_kwargs = Set(String).new
      ast_params.each_with_index do |param, slot|
        next if slot >= frame.locals.size
        if param.splat?
          frame.locals[slot] = collect_splat(args, pos, caller_line)
          pos = args.size
        elsif param.kwarg?
          declared_kwargs << param.name
          bind_kwarg_param(frame, proc, param, slot, kwargs, caller_line)
        elsif pos < args.size
          frame.locals[slot] = args[pos]
          pos += 1
        end
        # else: left at nil_value — either no arg was supplied for a
        # required param (always been silently permissive), or this
        # param has a default that the compiled prologue will apply.
      end
      check_unknown_keywords!(kwargs, declared_kwargs, proc, frame, caller_line)
    end

    # Binds a single kwarg param — split out purely to keep
    # `bind_args`'s own branch count down (Ameba's cyclomatic-
    # complexity check), no behavior difference from having this
    # inline. Three-way shape (see `bind_args`'s own doc comment for
    # the full rationale): supplied → bind directly; absent with a
    # default → leave at `nil_value` for the compiled prologue;
    # absent with no default → raise immediately, right here.
    private def bind_kwarg_param(frame : Frame, proc : ScriptProc, param : Param, slot : Int32,
                                 kwargs : Hash(String, Value)?, caller_line : Int32) : Nil
      if kwargs && (val = kwargs[param.name]?)
        frame.locals[slot] = val
      elsif param.default.nil?
        # No default AND never supplied — unlike a missing positional
        # param (silently left nil, always has been), this is
        # unambiguous: the caller was supposed to name it and didn't.
        # Raised directly, in plain Crystal, not deferred to the
        # compiled prologue — there's no expression to evaluate, just
        # a fixed fact already known.
        raise runtime_diagnostic(
          Diagnostic.new(
            code: "R011",
            primary: Span.new(line: caller_line, filename: frame.filename),
            data: {"name" => param.name, "method" => proc.name}
          ),
          current_frame,
          error_class: "ArgumentError"
        )
      end
      # else: left at nil_value for the compiled default prologue
      # (Op::HasKwarg) to fill — see that opcode's comment.
    end

    # A keyword name the caller passed but `proc` never declared at
    # all — real Ruby raises here too (`unknown keyword`), and
    # Adjutant is supposed to be a subset of Ruby, not a superset
    # that quietly accepts more. Reports the first such name; if the
    # caller got several wrong, fixing the first is what surfaces the
    # rest on the next run, same as any other single-name error in
    # this catalog (R008, R011 above).
    private def check_unknown_keywords!(kwargs : Hash(String, Value)?, declared : Set(String),
                                        proc : ScriptProc, frame : Frame, caller_line : Int32) : Nil
      return unless kwargs
      unknown = kwargs.keys.find { |k| !declared.includes?(k) }
      return unless unknown
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R012",
          primary: Span.new(line: caller_line, filename: frame.filename),
          data: {"name" => unknown, "method" => proc.name}
        ),
        current_frame,
        error_class: "ArgumentError"
      )
    end

    # Guards a call site that has no `Param` list to check keyword
    # names against at all — a class with no `initialize` (nowhere
    # for a keyword arg to bind; construct_object's own guard). Every
    # supplied name is therefore unsupported here; reports the first,
    # same one-name style as bind_args's own R011/R012. A no-op
    # (returns immediately) for the overwhelming majority of calls,
    # which pass no keyword args.
    private def reject_kwargs!(kwargs : Hash(String, Value)?, method : String, filename : String, line : Int32) : Nil
      return if kwargs.nil? || kwargs.empty?
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R012",
          primary: Span.new(line: line, filename: filename),
          data: {"name" => kwargs.first_key, "method" => method}
        ),
        current_frame,
        error_class: "ArgumentError"
      )
    end

    # Native-call counterpart to check_unknown_keywords! — same
    # unknown-name-reports-first R012 shape, but checked against a
    # NativeCallable's declared `kwarg_names : Set(String)` (see that
    # getter's doc comment) instead of a ScriptProc's ast_params. A
    # native callable that declares no kwarg_names at all (the
    # default, and every pre-existing native registration) rejects
    # every supplied name — behaviorally identical to the old
    # unconditional reject_kwargs! for those callables, just expressed
    # as "declared set happens to be empty" rather than a separate
    # unconditional guard.
    private def check_unknown_native_keywords!(kwargs : Hash(String, Value)?, declared : Set(String),
                                               method : String, filename : String, line : Int32) : Nil
      return if kwargs.nil? || kwargs.empty?
      unknown = kwargs.keys.find { |k| !declared.includes?(k) }
      return unless unknown
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R012",
          primary: Span.new(line: line, filename: filename),
          data: {"name" => unknown, "method" => method}
        ),
        current_frame,
        error_class: "ArgumentError"
      )
    end

    # for a splat param. Labeled the same way Op::MakeArray labels a
    # literal array (join of every element's label) — a splat-bound
    # array is exactly as much a container of its elements as one
    # built with `[...]`, and IFC shouldn't be able to tell them
    # apart. Records a RiskFlowEvent under the same "MakeArray" op
    # name for the same reason: to a risk-flow log reader, a splat
    # collecting args into an array and a literal `[...]` are the same
    # KIND of event. `line` is the CALL SITE's line (see
    # call_script_proc's `caller_line`), not the freshly pushed
    # callee frame's — that frame's own `line` is still 0 here, since
    # only execute's dispatch loop advances it once the callee's first
    # instruction actually runs.
    private def collect_splat(args : Array(Value), from : Int32, line : Int32) : Value
      elements = from < args.size ? args[from..] : [] of Value
      joined_label = elements.reduce(nil.as(RiskFlowLabel?)) { |acc, value| RiskFlowLabel.join(acc, value.label) }
      @risk_flow_log.record("MakeArray", elements.map(&.label), joined_label, line)
      Value.new(LabeledArray.new(elements, joined_label), joined_label)
    end

    # Minimal built-ins needed for specs to pass before stdlib lands.
    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_builtin(name : String,
                             args : Array(Value),
                             filename : String, line : Int32,
                             blk : ScriptProc? = nil,
                             kwargs : Hash(String, Value)? = nil) : Value?
      reject_kwargs!(kwargs, name, filename, line)
      case name
      when "puts"
        # `render_to_s`, not each arg's own hand-rolled case — real
        # dispatch for anything with an overridable `to_s`, matching
        # Op::Concat (string interpolation)'s own fix. Fixes a real,
        # pre-existing bug as a side effect: the OLD code here used
        # `arg.as_sym.to_s`, which (per `Sym#to_s`'s own colon-
        # inclusive quirk — see symbol_table.cr) printed `puts :sym`
        # as `:sym`, WITH the colon; real Ruby's `puts :sym` prints
        # `sym`. `render_to_s`'s symbol case already uses `.name`
        # (no colon), the same fix Op::Concat already got.
        str = args.map { |arg| render_to_s(arg, filename, line) }.join("\n")
        if ef = @effect
          ef.write_stdout(str + "\n")
        else
          STDOUT.puts(str)
        end
        Value.nil_value
      when "print"
        str = args.map { |arg| render_to_s(arg, filename, line) }.join
        if ef = @effect
          ef.write_stdout(str)
        else
          STDOUT.print(str)
        end
        Value.nil_value
      when "p"
        # `render_inspect`, not `arg.inspect` (Crystal-level) — same
        # fix as `puts`/`print` above, `inspect` instead of `to_s`.
        str = args.map { |arg| render_inspect(arg, filename, line) }.join("\n")
        if ef = @effect
          ef.write_stdout(str + "\n")
        else
          STDOUT.puts(str)
        end
        if args.size == 1
          args.first
        else
          joined_label = args.reduce(nil.as(RiskFlowLabel?)) { |acc, value| RiskFlowLabel.join(acc, value.label) }
          Value.new(LabeledArray.new(args.dup, joined_label), nil)
        end
      when "raise"
        cls = nil
        error_obj = nil
        msg = if args.empty?
                cls = builtin_class_by_name("RuntimeError")
                "unhandled exception"
              elsif args.first.rclass?
                # Raised with just a class, so instantiate class with next parameter
                # e.g. raise NameError, "boo"
                cls = args.first.as_rclass
                args[1]?.try(&.to_s) || cls.name
              elsif (obj = args.first.as_robject?) && obj.instance_of?("Exception")
                # Raised with instance of Exception/subclass
                # e.g. raise NameError.new("boo")
                error_obj = obj # already exception instance
                obj.to_s
              else
                # Raised arbitrary value which we turn into a String
                cls = builtin_class_by_name("RuntimeError")
                args.first.to_s
              end
        err_val = if error_obj
                    Value.robject(error_obj)
                  else
                    cls ? make_error_object(cls, msg) : Value.string(msg)
                  end
        # wrap it in our Runtime error
        raise RuntimeError.new(msg, filename, line, error_value: err_val)
      when "<=>"
        a = args[0]? || Value.nil_value
        b = args[1]? || Value.nil_value
        if a.robject? || b.robject?
          # A RubyObject with no `<=>` of its own isn't this
          # fallback's business — return Crystal `nil` (NOT
          # Value.nil_value) so dispatch_call's caller sees this as
          # "unhandled" and falls through to the ordinary undefined-
          # method raise (R008) below, per SCOPE.md's decision: no
          # implicit default `<=>`, an absence fails exactly like any
          # other undefined method call. (A RubyObject that DOES
          # define `<=>` never reaches exec_builtin at all —
          # dispatch_call's receiver-based step finds and calls it
          # directly, before falling back this far.)
          nil
        elsif sign = ValueOps.spaceship(a, b)
          Value.int(sign.to_i64)
        else
          Value.nil_value
        end
      when "require"
        path = args.first? ? args.first.as_string : ""
        if interp = @interpreter
          interp.require_module(path, filename)
        else
          # A bare VM is a supported configuration; it just cannot
          # require. That makes this the host's wiring, not the
          # script's fault — so H, not R010.
          raise HostStateError.new(Diagnostic.new(code: "H006"))
        end
      when "nil?"
        # Called as a method: args[0] is receiver
        recv = args.first? || Value.nil_value
        Value.bool(recv.null?)
      when "is_a?", "kind_of?"
        # Real Ruby aliases these exactly — same helper, no separate
        # logic. RubyObject receivers walk their own rclass chain;
        # other receivers (Integer today, more as builtins land)
        # resolve via Interpreter#builtin_class_for, since they carry
        # no rclass reference of their own.
        recv = args.first? || Value.nil_value
        target = args[1]?.try(&.as_rclass?)
        Value.bool(is_a_target?(recv, target))
      when "class"
        # Three receiver shapes, each resolved differently:
        #   - a RubyObject instance: its own rclass (e.g. an `A.new`
        #     instance's class is A)
        #   - a RubyClass itself (e.g. `Integer.class`, `A.class`):
        #     ITS rclass, not builtin_class_for — a class receiver
        #     isn't a value of the kind builtin_class_for resolves,
        #     it's the class object, whose own class is (almost
        #     always) Class itself
        #   - any other builtin-kind Value (5, "x", true, ...):
        #     Interpreter#builtin_class_for, same lookup is_a? uses
        recv = args.first? || Value.nil_value
        cls = recv.as_robject?.try(&.rclass) ||
              recv.as_rclass?.try(&.rclass) ||
              @interpreter.try(&.builtin_class_for(recv))
        cls ? Value.rclass(cls) : Value.nil_value
      when "superclass"
        # Only meaningful on a RubyClass receiver (`Integer.superclass`,
        # `Foo.superclass`) — real Ruby raises NoMethodError for
        # `5.superclass` since Integer instances don't have this
        # method, only Class/Module objects do. Object.superclass is
        # nil (the true root); any RubyObject or other value receiver
        # returns nil too, rather than raising, matching Adjutant's
        # generally forgiving-over-raising style for reflection methods.
        recv = args.first? || Value.nil_value
        sup = recv.as_rclass?.try(&.superclass)
        sup ? Value.rclass(sup) : Value.nil_value
      when "respond_to?"
        # Whether `recv.method_name` would find a real target — checks
        # every table dispatch_call itself would check, in the same
        # order, for the same three receiver shapes is_a?/.class use.
        # Real Ruby's respond_to? takes a Symbol (`respond_to?(:foo)`)
        # but a String works too here, since Adjutant doesn't
        # distinguish "foo" from :foo as strictly. Deliberately
        # conservative: doesn't check exec_builtin's fallback cases
        # (is_a?, class, to_s, ...) individually, so a method that
        # ONLY exists as a VM-level fallback will report
        # respond_to?(:to_s) as false even though calling it would
        # actually work. Rare enough in practice (those are all
        # near-universal methods scripts don't usually probe for) that
        # getting the common case right — user-defined and native
        # methods — matters more than exhaustive fallback coverage.
        recv = args.first? || Value.nil_value
        method_arg = args[1]? || Value.nil_value
        method_name = method_arg.as_sym?.try(&.name) || method_arg.as_string?
        Value.bool(method_name ? script_responds_to?(recv, method_name) : false)
      when "equal?"
        # Object identity, not value equality (that's `==`, a real
        # opcode — see Op::Eq). Two Value-wrapped primitives (ints,
        # bools, ...) with the same content are still "equal?" in
        # practice today, since Adjutant doesn't yet distinguish two
        # separately-boxed 5s from each other — this matches real
        # Ruby's behavior for immediates (Integer, Symbol, true/false/
        # nil) but would diverge from Ruby for two DIFFERENT String
        # instances holding the same text, which Adjutant can't yet
        # tell apart at the Value level either. Documented gap, not a
        # silent one.
        recv = args.first? || Value.nil_value
        other = args[1]? || Value.nil_value
        Value.bool(recv == other)
      when "dup", "clone"
        # RubyObject receivers only — see SCOPE.md's dup/clone entry.
        # Allocates a fresh RubyObject of the SAME rclass and shallow-
        # copies `ivars` (a new Hash, but the same Value references —
        # matching real Ruby: a copied String ivar and the original
        # still point at the same object until one is itself
        # reassigned). `initialize` is deliberately NOT run — dup/
        # clone construct a copy of existing state, not a new object
        # via the class's own constructor contract (which might
        # require args this call site doesn't have, or have side
        # effects that shouldn't run twice).
        #
        # If the class (or an ancestor) defines `initialize_copy`, it
        # runs after the shallow copy, receiving the ORIGINAL as its
        # one argument, `self` bound to the new copy — matching real
        # Ruby's hook for a class that needs to deep-copy a specific
        # field (a Config wrapping a mutable Array ivar, say) rather
        # than share it. Absent, the shallow copy above already IS
        # the complete result — real Ruby's own default
        # `Object#initialize_copy` does nothing beyond what dup/clone
        # already do in C before ever calling it, so skipping the
        # call entirely when undefined is equivalent, not a shortcut.
        #
        # Adjutant doesn't model frozen state at all (no `freeze`/
        # `frozen?` yet), so `dup` and `clone` are behaviorally
        # identical here — real Ruby's only difference between them
        # (clone preserves frozen-ness and singleton class, dup never
        # does) has nothing to attach to yet.
        #
        # Builtin-kind receivers (Integer, String, Array, Hash,
        # Symbol, true/false/nil, ...) are deliberately OUT of scope
        # here, not silently half-handled: real Ruby returns the
        # receiver itself for a true immediate (Integer, Symbol,
        # true/false/nil) but an independent copy for String/Array/
        # Hash, and Adjutant's Value model can't yet tell two
        # separately-boxed instances of the same collection apart at
        # all (the exact gap `equal?`, above, already documents) —
        # matching only the immediate half of that split would be
        # actively wrong for the other half, worse than a clear
        # NoMethodError. Falls through to `nil` (undefined method)
        # below, same as any other genuinely unhandled case.
        recv = args.first? || Value.nil_value
        if obj = recv.as_robject?
          copy = RubyObject.new(obj.rclass)
          copy.ivars.merge!(obj.ivars)
          copy_val = Value.robject(copy)
          if sym_id = @symbols.lookup("initialize_copy").try(&.value)
            if method = obj.rclass.find_method(sym_id)
              invoke(method, [recv], self_val: copy_val)
            end
          end
          copy_val
        else
          nil
        end
      when "to_s"
        recv = args.first? || Value.nil_value
        Value.string(recv.to_s)
      when "inspect"
        # Only reached for a receiver with no OTHER resolution path —
        # every type with its own real, registered `inspect`
        # (`RubyObject`/`Array`/`Hash`/`Range`/`Proc`, all inheriting
        # from or overriding `Object`'s default) resolves at an
        # earlier dispatch step and never reaches this fallback at
        # all. In practice, today, that means specifically a
        # `RubyClass` receiver — the explicit-receiver rclass branch
        # (above) only checks SINGLETON method tables, and no type
        # registers a native singleton `inspect` — so `MyClass.
        # inspect` fell all the way through to here and raised R008
        # (undefined method) before this case existed, even though
        # `MyClass.to_s` already worked via this exact same fallback
        # mechanism, one case up. `Value#inspect` (value.cr) already
        # has no special `RubyClass` branch of its own, deferring to
        # `to_s(io)` — so this produces the same qualified name
        # `to_s` does, matching real Ruby's own `MyClass.inspect ==
        # MyClass.to_s` for the DEFAULT case. A script's own `def
        # self.inspect` override is a real, separate, SCOPE.md-tracked
        # gap ("Object model" group) — this fallback is only ever
        # reached when no override (or default) was found any other
        # way, so it can't and doesn't paper over that.
        recv = args.first? || Value.nil_value
        Value.string(recv.inspect)
      when "to_i"
        recv = args.first? || Value.nil_value
        case
        when recv.int?    then recv
        when recv.float?  then Value.int(recv.as_float.to_i64)
        when recv.string? then Value.int(recv.as_string.to_i64? || 0_i64)
        else                   Value.int(0_i64)
        end
      when "to_f"
        recv = args.first? || Value.nil_value
        case
        when recv.float?  then recv
        when recv.int?    then Value.float(recv.as_int.to_f64)
        when recv.string? then Value.float(recv.as_string.to_f64? || 0.0)
        else                   Value.float(0.0)
        end
      when "length", "size"
        recv = args.first? || Value.nil_value
        case
        when recv.string? then Value.int(recv.as_string.size.to_i64)
        when recv.array?  then Value.int(recv.as_array.size.to_i64)
        when recv.hash?   then Value.int(recv.as_hash.size.to_i64)
        else                   Value.int(0_i64)
        end
      when "+"
        ValueOps.add(args[0], args[1], error_raiser(current_frame))
      when "-"
        ValueOps.op(args[0], args[1], :-, error_raiser(current_frame))
      when "*"
        ValueOps.op(args[0], args[1], :*, error_raiser(current_frame))
      when "/"
        ValueOps.div(args[0], args[1], error_raiser(current_frame))
      when "%"
        ValueOps.mod(args[0], args[1], error_raiser(current_frame))
      else
        nil
      end
    end

    # --- Operators ------------------------------------------------------------
    # The actual arithmetic/comparison/equality logic lives in
    # ValueOps (value_ops.cr) now — VM-independent, pure Value
    # dispatch, previously duplicated here across 8 separate methods
    # plus a third copy in the FakeContext spec helper. These two
    # `protected` wrappers exist only because NativeCallContext's real
    # implementation (NativeFunctionCall, in native_function_call.cr) delegates
    # to `@vm.compare`/`@vm.values_equal?` by name — the delegation
    # contract stays the same, the logic behind it moved.

    # `filename`/`line` default to the current frame's own position —
    # right for every VM-opcode call site (Op::Lt/Le/Gt/Ge below,
    # already inside whatever frame is being compared) — and
    # `NativeFunctionCall#compare` (native_function_call.cr) passes its own
    # explicit `@filename`/`@line` instead, same pattern `call_method`
    # already uses, so an R013 raised from a native method's own
    # comparison points at the native call site, not wherever the VM
    # last happened to be.
    protected def compare(a : Value, b : Value, op : Symbol,
                          filename : String = current_frame.filename,
                          line : Int32 = current_frame.line) : Bool
      # Real Ruby's own answer to "how do `</<=/>/>=` work for a
      # custom object" is the `Comparable` mixin, deriving all four
      # from one `<=>` — Adjutant has no mixins, so this is the fixed
      # VM rule standing in for it (see SCOPE.md's `<=>` decision).
      # Only reached for a RubyObject operand: ValueOps.compare
      # already handles every base-type pairing correctly and cheaply,
      # so this extra dispatch is skipped entirely for the overwhelming
      # majority of comparisons.
      if a.robject? || b.robject?
        compare_via_spaceship(a, b, op, filename, line)
      else
        ValueOps.compare(a, b, op)
      end
    end

    # NativeCallContext#add's own implementation — the same    # `error_raiser` wiring Op::Add itself uses (see this file's own
    # `when Op::Add` case), just reachable from native code. Doesn't
    # attempt a RubyObject `+` dispatch the way `compare`/`compare_via_spaceship`
    # does for `<=>` — no current native caller needs a user-defined
    # `+` (Range#step's own bounds are always base types in practice),
    # so that generality wasn't built until something actually needs
    # it, matching this codebase's own "don't build ahead of a real
    # user" convention.
    protected def add(a : Value, b : Value) : Value
      ValueOps.add(a, b, error_raiser(current_frame))
    end

    # `a` is always the receiver — `a < b` reads as `a.<=>(b)`, the
    # same left-to-right receiver convention every other infix
    # operator in Adjutant already uses. No "is `<=>` defined?"
    # pre-check: dispatch unconditionally, and let an absent `<=>`
    # fail exactly the way any other undefined method call already
    # does (an ordinary NameError-equivalent from `call_method`) —
    # consistent with the rest of the language, no new error shape for
    # this one case.
    private def compare_via_spaceship(a : Value, b : Value, op : Symbol,
                                      filename : String, line : Int32) : Bool
      sign_val = call_method(a, "<=>", [b], filename, line)
      unless sign_val.int?
        # Mirrors real Ruby exactly: `<=>` returning anything other
        # than an Integer (`nil` for a genuinely unorderable pair, or
        # any other value) makes `<`/`<=`/`>`/`>=` raise, confirmed
        # directly against a real `Comparable`-including class in
        # `irb` (`ArgumentError: comparison of Foo with Foo failed`) —
        # not a case ValueOps's own "never raises" comparison
        # philosophy extends to, since that philosophy is about an
        # unrecognized TYPE PAIRING (a base-type default), not a
        # script's own method returning a value that breaks its own
        # contract.
        raise runtime_diagnostic(
          Diagnostic.new(
            code: "R013",
            primary: Span.new(line: line, filename: filename),
            data: {
              "left"  => describe_value(a),
              "right" => describe_value(b),
              "value" => sign_val.inspect,
            }
          ),
          current_frame,
          error_class: "ArgumentError"
        )
      end
      sign = sign_val.as_int
      case op
      when :<  then sign < 0
      when :<= then sign <= 0
      when :>  then sign > 0
      when :>= then sign >= 0
      else
        false
      end
    end

    protected def values_equal?(a : Value, b : Value) : Bool
      if range_receiver?(a) && range_receiver?(b)
        range_values_equal?(a, b)
      elsif a.robject? && b.robject? && script_responds_to?(a, "<=>")
        # Real Ruby: `Object#==` is identity by default, but a class
        # that mixes in `Comparable` gets `==` DERIVED from `<=>`
        # instead — `(a <=> b) == 0`, with `<=>` returning anything
        # other than an Integer (including nil, for a genuinely
        # unorderable pair) or raising treated as simply "not equal"
        # rather than propagating, matching Comparable#=='s own
        # non-raising contract (confirmed against MRI: `<`/`<=`/`>`/
        # `>=` DO raise ArgumentError on a bad `<=>` result — see
        # compare_via_spaceship above — but `==` never does; only
        # identity-vs-value differs, this asymmetry is real Ruby
        # behavior, not an Adjutant simplification). Adjutant has no
        # mixin system to hang this off an actual `Comparable`
        # inclusion, so — same as compare_via_spaceship already does
        # for `<`/`<=`/`>`/`>=` — this is the fixed VM rule standing
        # in for it: ANY RubyObject with its own `<=>` gets `==`
        # derived from it for free, without needing `include
        # Comparable` to opt in. `script_responds_to?` gates this on
        # `<=>` genuinely being defined (native or script), so a
        # plain RubyObject with no `<=>` still falls through to
        # ordinary identity below, unchanged from before this existed.
        robject_equal_via_spaceship?(a, b)
      else
        ValueOps.equal?(a, b)
      end
    end

    # See values_equal?'s own comment for the full reasoning — this is
    # just the "call `<=>`, swallow anything that isn't a clean zero
    # result" mechanics, split out to keep values_equal? itself
    # readable. Deliberately rescues RuntimeError (a script-level
    # `raise` inside the `<=>` method itself, e.g. comparing against
    # an incompatible type) into `false` rather than letting it
    # propagate — the one place in this codebase a script-raised
    # error is intentionally swallowed rather than surfaced, because
    # that's genuinely how Comparable#== behaves in real Ruby, not an
    # Adjutant-specific leniency.
    private def robject_equal_via_spaceship?(a : Value, b : Value) : Bool
      sign_val = call_method(a, "<=>", [b])
      sign_val.int? && sign_val.as_int == 0
    rescue RuntimeError
      false
    end

    # `Op::Add`/`Op::Sub`'s own dispatch — mirrors compare/
    # values_equal?'s "left receiver's own method wins when it has
    # one" rule, but for `+`/`-` specifically. Unlike `<=>` (dispatched
    # unconditionally, per SCOPE.md's decision — an absent `<=>` fails
    # like any other undefined method call) and unlike `==` (silently
    # falls back to identity when no `<=>` exists), `+`/`-` fall back
    # to `ValueOps`'s own base-type handling whenever the LEFT operand
    # isn't a `RubyObject` with its own defined `+`/`-` — this is
    # additive to the base-type arithmetic already there, not a
    # replacement for it, so `1 + 2` and `"a" + "b"` are completely
    # unaffected and never even reach `script_responds_to?`.
    #
    # Found necessary while building a real `Time` builtin (`t + 60`)
    # — before this, arithmetic operators were opcode-only with no
    # method-table consultation for ANY receiver, base type or
    # RubyObject alike (see DEVELOPMENT.md's "Some operators are
    # overloaded across base types" section, which explicitly left
    # this open: "no equivalent yet exists for -/*/, since nothing
    # native has needed them generically yet — follow the same
    # pattern... if one does"). `Time` is that first real need for
    # `+`/`-`; `Legate::Path#/` (`legate/path.cr`) is the first real
    # need for `/` too (see `exec_div`, below) — `*` alone remains
    # untouched, since nothing needs it yet either — same "don't build
    # ahead of a real user" convention, not an oversight. SCOPE.md's
    # Will Fix entry for this updated accordingly (`/` moved from
    # "still a gap" to "closed", only `*`/`%` remain).
    private def exec_add(lhs : Value, rhs : Value, f : Frame) : Value
      if lhs.robject? && script_responds_to?(lhs, "+")
        call_method(lhs, "+", [rhs], f.filename, f.line)
      else
        ValueOps.add(lhs, rhs, error_raiser(f))
      end
    end

    private def exec_sub(lhs : Value, rhs : Value, f : Frame) : Value
      if lhs.robject? && script_responds_to?(lhs, "-")
        call_method(lhs, "-", [rhs], f.filename, f.line)
      else
        ValueOps.op(lhs, rhs, :-, error_raiser(f))
      end
    end

    # See exec_add's own comment — same dispatch shape, for `/`.
    # `Legate::Path#/` (LEGATE.md §5.1) is what made this a real,
    # not speculative, need.
    private def exec_div(lhs : Value, rhs : Value, f : Frame) : Value
      if lhs.robject? && script_responds_to?(lhs, "/")
        call_method(lhs, "/", [rhs], f.filename, f.line)
      else
        ValueOps.div(lhs, rhs, error_raiser(f))
      end
    end

    # Real Ruby's Range#== (and #eql?, defined identically for Range)
    # compares by CONTENT — same min/max/exclusive — not identity, and
    # NOT via `<=>` either (Range has no `<=>` of its own). checked
    # ahead of the `<=>`-derivation branch above (values_equal?) since
    # Range predates that mechanism and would need its own `<=>` to
    # use it anyway — this stays a direct special case, the same
    # exception Array/Hash already get in ValueOps.equal?'s own case
    # statement.
    # Lives here rather than in ValueOps itself because identifying
    # "is this specifically a Range" needs `range_receiver?`
    # (`builtin_class_by_name`, VM-only), and reading the ivars needs
    # `@symbols` — neither reachable from ValueOps, which only ever
    # operates on bare Values with no VM access at all.
    private def range_values_equal?(a : Value, b : Value) : Bool
      ao, bo = a.as_robject, b.as_robject
      min_sym = @symbols.intern("__min").value
      max_sym = @symbols.intern("__max").value
      excl_sym = @symbols.intern("__exclusive").value
      ValueOps.equal?(ao.ivars[min_sym], bo.ivars[min_sym]) &&
        ValueOps.equal?(ao.ivars[max_sym], bo.ivars[max_sym]) &&
        ao.ivars[excl_sym].as_bool == bo.ivars[excl_sym].as_bool
    end

    # --- Index helpers ------------------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_get_index(target : Value, idx : Value, safe : Bool,
                               filename : String, line : Int32) : Value
      return Value.nil_value if safe && target.null?
      case
      when target.array? && idx.int?
        i = idx.as_int
        arr = target.as_array
        i = arr.size + i if i < 0
        (i >= 0 && i < arr.size) ? arr[i] : Value.nil_value
      when target.hash?
        target.as_hash[idx]? || Value.nil_value
      when target.string? && idx.int?
        i = idx.as_int.to_i
        s = target.as_string
        i = s.size + i if i < 0
        (i >= 0 && i < s.size) ? Value.string(s[i].to_s, target.label) : Value.nil_value
      when target.string? && range_receiver?(idx)
        exec_get_index_string_range(target, idx)
      else
        exec_get_index_fallback(target, idx, filename, line)
      end
    end

    # `obj[i]`-style bracket indexing on anything that ISN'T one of the
    # hardcoded Array/Hash/String cases above used to just silently
    # return nil, unconditionally — found 2026-08-14 while wiring up
    # MatchData#[] (`builtins/regexp.cr`): `Op::GetIndex`/`Op::SafeIndex`
    # never consulted a receiver's own method table at all, so a NATIVE
    # `[]` method (MatchData's, here) was registered correctly but
    # completely unreachable via `md[0]` bracket syntax — the exact
    # same "declared but unreachable" trap UNSUPPORTED.md's own
    # standing principles exist to catch, just found in existing
    # indexing code rather than new syntax.
    #
    # This fallback closes the NATIVE half of that gap: a RubyObject
    # receiver with a native `[]` method now gets it called for real,
    # synchronously, via `call_native` — the same call `dispatch_call`'s
    # own receiver branch makes for an ordinary `.foo` call, just
    # reached from indexing instead. A SCRIPT-DEFINED `[]` is
    # deliberately still NOT handled here and still silently returns
    # nil: `call_script_proc` pushes a new VM frame and returns a
    # sentinel, relying on the normal `Op::Call`/`Op::Ret` dispatch loop
    # to later pop it and deliver the real result — `exec_get_index` is
    # called synchronously from inside a single opcode's handler and
    # has no equivalent mechanism to suspend and resume around that.
    # Moot in practice today anyway: `def [](i)` can't even be written
    # in script (see UNSUPPORTED.md's U017 — no combined `[]` lexer
    # token, so `parse_def` trips on the stray `]` before it could ever
    # produce one), so only NATIVE `[]` methods exist to reach at all
    # right now. Flagged in SCOPE.md as a real, separate, still-open
    # gap for whenever a script-definable `[]` is worth adding.
    private def exec_get_index_fallback(target : Value, idx : Value,
                                        filename : String, line : Int32) : Value
      return Value.nil_value unless obj = target.as_robject?
      sym_id = @symbols.lookup("[]").try(&.value)
      return Value.nil_value unless sym_id
      native = obj.rclass.find_native_method(sym_id)
      return Value.nil_value unless native
      call_native(native, [target, idx], filename, line, nil, "#{obj.rclass.name}#[]")
    end

    private def exec_set_index(target : Value, idx : Value, val : Value) : Nil
      case
      when target.array? && idx.int?
        i = idx.as_int.to_i
        arr = target.as_array
        i = arr.size + i if i < 0
        if i >= 0 && i < arr.size
          arr[i] = val
          arr.label = RiskFlowLabel.join(arr.label, val.label)
        end
      when target.hash?
        h = target.as_hash
        h[idx] = val
        h.label = RiskFlowLabel.join(h.label, val.label)
      end
    end

    private def exec_binary(inst : Instruction, &block : Value, Value -> Value) : Nil
      b = pop
      a = pop
      result = block.call(a, b).with_label(RiskFlowLabel.join(a.label, b.label))
      @risk_flow_log.record(inst.op.to_s, [a.label, b.label], result.label, current_frame.line)
      push(result)
    end

    # Builds the `on_error` proc ValueOps' arithmetic methods (add/op/
    # div/mod/int_op/shl) take — the only bridge those VM-independent
    # methods need back into VM#runtime_error, so the rich,
    # script-catchable error object (a real RuntimeError-or-other
    # RubyObject, not just a message string) is still built in exactly
    # one place. Takes the `error_class` straight through from the
    # caller (ValueOps now classifies its own failures — "TypeError",
    # "ZeroDivisionError" — rather than everything collapsing into a
    # generic RuntimeError regardless of what actually went wrong).
    private def error_raiser(frame : Frame) : ValueOps::OnError
      ->(msg : String, error_class : String) { raise runtime_error(msg, frame, error_class: error_class) }
    end

    private def runtime_error(msg : String, frame : Frame = current_frame, cause = nil, error_class : String = "RuntimeError") : RuntimeError
      cls = builtin_class_by_name(error_class)
      err_val = cls ? make_error_object(cls, msg) : nil
      RuntimeError.new(msg, frame, cause, error_value: err_val)
    end

    # Same as runtime_error, but carries a structured Diagnostic for
    # the host alongside the script-visible error object.
    #
    # The script-visible object gets the diagnostic's SUMMARY only —
    # not the code, the "why", or the "help". A script that rescues
    # this and prints `e.message` should see an ordinary Ruby-shaped
    # sentence; the code and the explanation are for whoever is reading
    # the interpreter's output, and a script has no use for either.
    #
    # Spans here carry a line and no column: `Frame` doesn't record
    # one. The renderer quotes the source line and omits the caret row.
    # `error_class` is the Ruby class a script sees when it rescues
    # this. It has to stay independently settable from the diagnostic
    # code: the code classifies the failure for whoever reads the
    # report, while the class governs `rescue` semantics and must match
    # real Ruby's choice — an unresolved bare name is a `NameError`
    # there, and Adjutant is a proper subset, so it is one here too.
    private def runtime_diagnostic(diag : Diagnostic, frame : Frame = current_frame,
                                   cause = nil, error_class : String = "RuntimeError") : RuntimeError
      cls = builtin_class_by_name(error_class)
      err_val = cls ? make_error_object(cls, diag.summary) : nil
      RuntimeError.new(diag, frame, cause, error_value: err_val)
    end

    # Native-method counterpart to the script-raised diagnostics
    # elsewhere in this file (undefined_constant, excluded_construct,
    # ...) — same runtime_diagnostic machinery, just reachable from
    # outside the VM via NativeCallContext#raise_error (see that
    # method's own comment for why this exists at all). `filename`/
    # `line` are the CALL SITE's, passed through from
    # NativeFunctionCall's own getters, not this frame's — matching
    # every other native-method diagnostic (e.g. call_native's own
    # N001 rescue) which points at where the script called the native
    # method, not at native code the script never sees.
    protected def raise_native_error(code : String, data : Hash(String, String),
                                     error_class : String, filename : String, line : Int32) : NoReturn
      raise runtime_diagnostic(
        Diagnostic.new(code: code, primary: Span.new(line: line, filename: filename), data: data),
        current_frame,
        error_class: error_class
      )
    end

    # Same as raise_native_error, but for a target class that can't be
    # resolved by name (see NativeCallContext#raise_error_class's own
    # comment — a nested class like Legate::Malformed has no flat
    # global entry for builtin_class_by_name to find) AND for a
    # dynamically-COMPUTED message rather than an ErrorCatalog-coded
    # one — Legate's own error messages are built per-call (a path, a
    # byte count, LEGATE.md §9.1's "message MUST hint at" column), not
    # fixed templates, so routing them through Diagnostic/ErrorCatalog
    # (which requires a REGISTERED catalog entry per code, and exists
    # for ADJUTANT'S OWN coded diagnostics — parse/compile/core-
    # runtime errors) would be the wrong fit entirely, not just an
    # awkward one. Mirrors exec_builtin's own "raise" case (the
    # `raise ClassName, "msg"` script-level path) instead: build the
    # error object directly from the given class and a plain message
    # string, no Diagnostic/code involved at all — `code` here is
    # NOT an ErrorCatalog key, just a label for whoever reads
    # `RuntimeError#message`/logs, matching how a script's own
    # `raise Foo, "msg"` carries no code either.
    protected def raise_native_error_class(message : String, error_class : RubyClass,
                                           filename : String, line : Int32) : NoReturn
      err_val = make_error_object(error_class, message)
      raise RuntimeError.new(message, filename, line, error_value: err_val)
    end

    # An unresolved constant. Reports a deliberately excluded name as
    # such, and anything else as an ordinary uninitialized constant.
    #
    # `bare_name` lets a qualified lookup (`Foo::ObjectSpace`) be tested
    # against the table by its last segment while still reporting the
    # full path the script wrote.
    private def undefined_constant(name : String, frame : Frame,
                                   bare_name : String? = nil) : RuntimeError
      if code = ErrorCatalog::EXCLUDED_CONSTANTS[bare_name || name]?
        return excluded_construct(code, name, frame.filename, frame.line)
      end
      script_diagnostic("R003", {"name" => name}, frame)
    end

    # A construct Adjutant will never support, reported as such rather
    # than as an undefined name.
    #
    # Raised as a NameError like R008, and for the same reason: from the
    # script's side the name genuinely does not resolve, and a script
    # that rescues NameError should still catch this. The code is what
    # tells the reader it is never going to resolve.
    private def excluded_construct(code : String, name : String,
                                   filename : String, line : Int32) : RuntimeError
      runtime_diagnostic(
        Diagnostic.new(
          code: code,
          primary: Span.new(line: line, filename: filename),
          data: {"construct" => name}
        ),
        current_frame,
        error_class: "NameError"
      )
    end

    # Shorthand for the ordinary script-fault diagnostics, which all
    # have the same shape: a code, some substitutions, and the frame.
    private def script_diagnostic(code : String, data : Hash(String, String), frame : Frame) : RuntimeError
      runtime_diagnostic(
        Diagnostic.new(code: code, primary: frame_span(frame), data: data),
        frame
      )
    end

    # A value's type as a script author would name it. The old messages
    # interpolated `v.raw.class`, which leaks Crystal type names
    # (`Int64`, `Nil`) at someone writing Ruby.
    private def describe_value(value : Value) : String
      if obj = value.as_robject?
        return obj.rclass.name
      end
      if cls = value.as_rclass?
        return cls.name
      end
      @interpreter.try(&.builtin_class_for(value)).try(&.name) || "this value"
    end

    # Shorthand for the internal (`I`) diagnostics raised from inside
    # the dispatch loop, which all have the same shape: a code, a
    # couple of substitutions, and the frame in hand.
    private def internal_diagnostic(code : String, data : Hash(String, String), frame : Frame) : RuntimeError
      runtime_diagnostic(
        Diagnostic.new(code: code, primary: frame_span(frame), data: data),
        frame
      )
    end

    # Span for a failure the VM detected, from the frame it happened
    # in. Line only — see runtime_diagnostic.
    private def frame_span(frame : Frame) : Span
      Span.new(line: frame.line, filename: frame.filename)
    end

    # Constants are assign-once, and that single rule catches two
    # genuinely different mistakes. Reporting them as one — which the
    # message here used to do, mentioning class reopening even to a
    # script that had just written `FOO = 1` twice — makes each case
    # read as noise to whoever hit the other one.
    #
    #   - Both values are classes/modules: this is `class Foo; end`
    #     written twice, i.e. reopening. A deliberately unsupported
    #     construct (U003), and the reader needs to know it is never
    #     coming rather than that some constant rule fired.
    #   - Otherwise: an ordinary constant reassigned (R001). The
    #     assign-once rule working as intended, and a normal fault to
    #     fix in the script.
    private def constant_reassignment(existing : Value, replacement : Value,
                                      name : String, frame : Frame) : RuntimeError
      reopening = !existing.as_rclass?.nil? && !replacement.as_rclass?.nil?
      runtime_diagnostic(
        Diagnostic.new(
          code: reopening ? "U003" : "R001",
          primary: frame_span(frame),
          data: {"name" => name}
        ),
        frame
      )
    end

    # Same shape as runtime_error, but tags the script-visible error
    # object as NameError instead of RuntimeError — used for the
    # "no local, no native, no global, no builtin" dispatch miss,
    # matching real Ruby's NameError for an unresolved bare
    # identifier. Takes filename/line directly (not a Frame) since
    # its one caller, dispatch_call, only has those two in scope.
    private def name_error(msg : String, filename : String, line : Int32, cause = nil) : RuntimeError
      cls = builtin_class_by_name("NameError")
      err_val = cls ? make_error_object(cls, msg) : nil
      RuntimeError.new(msg, filename, line, cause, error_value: err_val)
    end

    # Look up any builtin/bootstrapped RubyClass by name — error
    # classes (Exception, StandardError, RuntimeError, ... — see
    # Interpreter#bootstrap_error_classes) and other builtins
    # registered into globals the same way (e.g. Range — see
    # bootstrap_builtin_classes/make_range_object). Returns nil if the
    # interpreter hasn't registered it (shouldn't happen in practice,
    # but VM shouldn't hard-fail if it does).
    private def builtin_class_by_name(name : String) : RubyClass?
      sym = @symbols.lookup(name)
      return nil unless sym
      @globals[sym.value]?.try(&.as_rclass?)
    end

    # Build a RubyObject of the Range class with its @min/@max/
    # @exclusive ivars set — the real-object replacement for the
    # earlier `[start, end, exclusive_flag]` LabeledArray stand-in
    # (see Op::MakeRange). Ivar names are double-underscore-prefixed
    # (`__min` etc.) to avoid colliding with a same-named ivar a
    # script might set on some OTHER object — Range instances are
    # never script-subclassed today, but there's no reason to claim
    # the unprefixed names if a future change did allow that.
    # Native-method accessors in builtins/range.cr intern the same
    # names and must be kept in sync with this.
    private def make_range_object(rstart : Value, rend : Value, exclusive : Bool,
                                  label : RiskFlowLabel?) : Value
      cls = builtin_class_by_name("Range")
      unless cls
        raise runtime_diagnostic(
          Diagnostic.new(
            code: "I004",
            primary: frame_span(current_frame),
            data: {
              "class" => "Range",
            }
          )
        )
      end
      obj = RubyObject.new(cls)
      obj.ivars[@symbols.intern("__min").value] = rstart
      obj.ivars[@symbols.intern("__max").value] = rend
      obj.ivars[@symbols.intern("__exclusive").value] = Value.bool(exclusive)
      Value.robject(obj, label)
    end

    # Companion to make_range_object above, for Op::MakeRegex — see
    # that op's own comment and Builtins.compile_regex for the actual
    # compile step. `ctx: nil` there is deliberate: a regex LITERAL
    # (unlike a `Regexp.new(...)` call) has no NativeCallContext in
    # scope, so an invalid pattern is turned into the same R021/
    # RegexpError here that `NativeCallContext#raise_error` would
    # produce for the constructor form — one error shape regardless of
    # which syntax produced the bad pattern.
    private def make_regexp_object(pattern : String, flags : Int32, label : RiskFlowLabel?) : Value
      cls = builtin_class_by_name("Regexp")
      unless cls
        raise runtime_diagnostic(
          Diagnostic.new(
            code: "I004",
            primary: frame_span(current_frame),
            data: {
              "class" => "Regexp",
            }
          )
        )
      end
      regex =
        begin
          Builtins.compile_regex(pattern, flags, nil)
        rescue ex : ::Exception
          raise runtime_diagnostic(
            Diagnostic.new(
              code: "R021",
              primary: frame_span(current_frame),
              data: {"reason" => ex.message || "invalid pattern"}
            ),
            error_class: "RegexpError"
          )
        end
      obj = RegexpObject.new(cls, regex)
      # Same "seed the ivar with the same label as the object itself"
      # fix as Regexp.new's own constructor (builtins/regexp.cr) —
      # `label` here already came from the interpolated pattern
      # string's own label (see Op::MakeRegex's caller), so an
      # interpolated `/#{tainted}/`'s `#source` needs to reflect that,
      # not just the Regexp object as a whole.
      obj.ivars[@symbols.intern("__source").value] = Value.string(pattern, label)
      obj.ivars[@symbols.intern("__options").value] = Value.int(flags)
      Value.robject(obj, label)
    end

    # Wraps a ScriptProc (already built by the compiler for a Lambda
    # node — see compile_lambda) in a real Proc RubyObject. See
    # builtins/proc.cr and SCOPE.md Piece C: only Lambda-node output
    # goes through this; call-site block literals and def bodies keep
    # using the bare sproc Value directly (Op::MakeProc with a=0),
    # never reach here.
    private def make_lambda_object(sproc : ScriptProc, label : RiskFlowLabel?, outer_locals : OuterChain?,
                                   filename : String, line : Int32) : Value
      cls = builtin_class_by_name("Proc")
      unless cls
        raise runtime_diagnostic(
          Diagnostic.new(
            code: "I004",
            primary: frame_span(current_frame),
            data: {
              "class" => "Proc",
            }
          )
        )
      end
      obj = RubyObject.new(cls)
      obj.ivars[@symbols.intern("__sproc").value] = Value.proc(sproc)
      # `filename`/`line` — the CREATION site (`f.filename`/`f.line` at
      # the moment `Op::MakeProc` ran for this literal, passed in by
      # the caller), not anything about where `.call` happens to be
      # invoked from later — matches real Ruby's own `Proc#to_s`,
      # which reports where a proc/lambda was DEFINED. Real Ruby also
      # includes a memory address (`#<Proc:0x... file:line>`) — see
      # `builtins/proc.cr`'s own `to_s`/`inspect` comment for why this
      # deliberately doesn't (no debugging value here, matching
      # `Object#inspect`'s own default omitting it for the same
      # reason).
      obj.ivars[@symbols.intern("__filename").value] = Value.string(filename)
      obj.ivars[@symbols.intern("__line").value] = Value.int(line.to_i64)
      # The lambda's true lexical parent scope, captured at THIS
      # evaluation of the literal (not shared across other
      # evaluations of the same source lambda, e.g. inside a loop —
      # each RubyObject instance gets its own snapshot). See
      # RubyObject#outer_locals's own comment for why this lives here
      # rather than in ivars.
      obj.outer_locals = outer_locals
      Value.robject(obj, label)
    end

    # Build a RubyObject of `cls` with its `message` ivar set — the
    # shape both explicit `raise` and internal VM errors use so a
    # rescue variable can call `.message` on either uniformly.
    private def make_error_object(cls : RubyClass, message : String) : Value
      obj = RubyObject.new(cls)
      msg_sym = @symbols.intern("message")
      obj.ivars[msg_sym.value] = Value.string(message)
      Value.robject(obj)
    end

    # Extract a plain string message from an error Value — the
    # message ivar for a RubyObject, the string itself for a plain
    # string, else its to_s. Shared by Op::Reraise and Op::EndEnsure,
    # which both need to reconstruct a Crystal exception from a
    # Value without losing the original class/identity.
    private def error_message(val : Value) : String
      if obj = val.as_robject?
        msg_sym = @symbols.intern("message")
        m = obj.ivars[msg_sym.value]?
        m ? (m.string? ? m.as_string : m.to_s) : obj.rclass.name
      elsif val.string?
        val.as_string
      else
        val.to_s
      end
    end

    # Clears the rescue portion of the frame's top handler entry —
    # we're past the point where a matching rescue applies for this
    # construct, whether because its body succeeded (Op::EndTry) or
    # because the error unwind loop just matched and is jumping in.
    # If the entry has no linked ensure_ip, nothing else will ever
    # pop it (Op::EnterEnsure only fires when there's an ensure body),
    # so pop it now — otherwise leave it for EnterEnsure to remove
    # once the ensure body it's still holding onto actually runs.
    private def clear_rescue_portion(frame : Frame) : Nil
      if top = frame.handlers.last?
        top.rescue_ip = nil
        frame.handlers.pop? if top.ensure_ip.nil?
      end
    end
  end
end
