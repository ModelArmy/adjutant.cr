require "./bytecode"
require "./symbol_table"
require "./value"
require "./value_ops"
require "./ast"
require "./risk_flow_policy"
require "./risk_flow_decision"

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
    # Not used by the VM at all; kept solely so RiskWalker can walk a
    # method's actual control-flow shape (branches, loops) rather than
    # re-deriving it from bytecode jump targets. See DEVELOPMENT.md's
    # "Structured risk" section.
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

    # Captured locals from the enclosing frame (for block closures).
    # nil for method frames; set to the enclosing frame's locals for blocks.
    property outer_locals : Array(Value)?

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
    # might later `yield` to.
    property block_outer_locals : Array(Value)?

    def initialize(@proc, @chunk, @stack_base, @filename, @block = nil, outer : Array(Value)? = nil,
                   @self_val : Value = Value.nil_value, @lexical_scope : RubyClass? = nil,
                   @block_outer_locals : Array(Value)? = nil)
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

    def initialize(message : String, @filename = "<script>", @line = 0, cause = nil, @error_value = nil)
      super(message, cause)
    end

    def initialize(message : String, frame : Frame, cause = nil, @error_value = nil)
      @filename = frame.filename
      @line = frame.line
      super(message, cause)
    end
  end

  # The bytecode VM.
  #
  # One VM instance per script execution. Holds the value stack,
  # call frame stack, globals, and execution state.
  class VM
    MAX_STACK = 4096

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
      @current_block_locals = nil.as(Array(Value)?)
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
    end

    # Execute a compiled chunk and return the result.
    def run(chunk : Chunk, filename : String = "<script>", local_count : Int32 = 0) : Value
      raise RuntimeError.new("Must be fresh VM to run a compiled chunk.", filename) unless @frames.empty?
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
    # `outer_locals`, when given, overrides the outer/closure scope
    # the invoked proc sees — needed for Proc#call (builtins/proc.cr),
    # where `proc` is a `->(){}` lambda that may be called arbitrarily
    # later, from an arbitrarily different frame than the one it was
    # defined in. Defaults to nil, which falls back to the CURRENT
    # frame's locals (`f.locals` below) — correct for every other
    # caller of this method (Array#each/Range#each/Hash#each's `blk`
    # param, etc.), since those are always a call-site block literal
    # still being invoked live, in the very frame that wrote it —
    # there is no defining-frame/calling-frame gap for that case, so
    # "the current frame's locals" and "the block's true creation-site
    # locals" are the same array. See RubyObject#outer_locals and
    # Op::MakeProc's snapshot (vm.cr) for where a Proc's real
    # closure snapshot is captured, and the 2026-07-20 closure-capture
    # bug (research/IFC_DESIGN.md) this override fixes for lambdas
    # specifically.
    protected def invoke(proc : ScriptProc, args : Array(Value), self_val : Value? = nil,
                         outer_locals : Array(Value)? = nil) : Value
      saved_frames = @frames
      saved_stack = @stack
      saved_ins_count = @instruction_count
      saved_cur_block = @current_block
      saved_cur_block_locals = @current_block_locals
      result = Value.nil_value
      begin
        f = current_frame # before replacing @frames
        inherited_self = self_val || f.self_val
        inherited_lexical = proc.lexical_scope || f.lexical_scope
        effective_outer = outer_locals || f.locals
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
          lexical_scope: inherited_lexical, lexical_override: true)
        # Let the VM execute the chunk
        result = execute
      ensure
        @frames = saved_frames
        @stack = saved_stack
        @instruction_count = saved_ins_count
        @current_block = saved_cur_block
        @current_block_locals = saved_cur_block_locals
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
        cls = cls.superclass
      end
      false
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
      raise runtime_error("class variable access outside of a class/module body", f)
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
                           outer : Array(Value)? = nil, self_val : Value = Value.nil_value, lexical_scope : RubyClass? = nil,
                           block_outer_locals : Array(Value)? = nil) : Frame
      if @limits.call_depth_limit > 0 && @frames.size >= @limits.call_depth_limit
        raise runtime_error("call stack too deep (limit: #{@limits.call_depth_limit})")
      end
      frame = Frame.new(proc, proc.chunk, stack_base, filename, block, outer, self_val, lexical_scope, block_outer_locals)
      @frames.push(frame)
      frame
    end

    private def pop_frame : Frame
      @frames.pop
    end

    private def current_frame : Frame
      @frames.last
    end

    private def push(v : Value) : Nil
      raise runtime_error("stack overflow") if @stack.size >= MAX_STACK
      @stack.push(v)
    end

    private def pop : Value
      raise runtime_error("stack underflow") if @stack.size <= current_frame.stack_base
      @stack.pop
    end

    private def peek : Value
      @stack.last
    end

    private def tick : Nil
      @instruction_count += 1
      if @limits.instruction_limit > 0 && @instruction_count > @limits.instruction_limit
        raise runtime_error("instruction limit exceeded (#{@limits.instruction_limit})")
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
              raise runtime_error("uninitialized constant #{sym.name}", f)
            end
            push(val)
          when Op::SetConstant
            sym = chunk.consts[inst.c].as_sym
            val = pop
            target = f.self_val.as_rclass? || f.lexical_scope
            # Constants are assign-once — real Ruby only WARNS on
            # reassignment (still permits it); Adjutant deliberately
            # makes it a hard error instead (2026-07-18, ahead of
            # Piece D — see SCOPE.md's Must Fix history and the
            # "Class/module reopening" Won't Fix entry). This is what
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
              if target.constants.has_key?(sym.value)
                raise runtime_error("constant #{target.name}::#{sym.name} already initialized — Adjutant does not permit constant reassignment (this includes redefining/reopening a class or module)", f)
              end
              target.constants[sym.value] = val
            else
              if @globals.has_key?(sym.value)
                raise runtime_error("constant #{sym.name} already initialized — Adjutant does not permit constant reassignment (this includes redefining/reopening a class or module)", f)
              end
              @globals[sym.value] = val
            end
            push(val)
          when Op::GetConstantFrom
            sym = chunk.consts[inst.c].as_sym
            ns_val = pop
            unless ns = ns_val.as_rclass?
              raise runtime_error("#{ns_val} is not a class/module", f)
            end
            val = ns.constants[sym.value]?
            unless val
              raise runtime_error("uninitialized constant #{ns.name}::#{sym.name}", f)
            end
            push(val)
          when Op::GetGlobalConstant
            sym = chunk.consts[inst.c].as_sym
            val = @globals[sym.value]?
            unless val
              raise runtime_error("uninitialized constant #{sym.name}", f)
            end
            push(val)

            # --- Stack ops ------------------------------------------------------
          when Op::GetIndex
            idx = pop
            target = pop
            push(exec_get_index(target, idx, safe: false))
          when Op::SafeIndex
            idx = pop
            target = pop
            push(exec_get_index(target, idx, safe: true))
          when Op::SetIndex
            val = pop
            idx = pop
            target = pop
            exec_set_index(target, idx, val)
            @risk_flow_log.record("SetIndex", [target.label, val.label], target.label, f.line)
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
            @current_block_locals = @current_block ? f.locals : nil
          when Op::Call, Op::SafeCall
            sym = chunk.consts[inst.c].as_sym
            argc = inst.a.to_i
            safe = inst.b & 0b01_u16 != 0
            has_receiver = inst.b & 0b10_u16 != 0

            args = @stack.last(argc)
            @stack.pop(argc) if argc > 0

            depth_before = @frames.size
            result = dispatch_call(sym.name, args, safe, f.filename, inst.line, @current_block, has_receiver,
              blk_outer: @current_block_locals, self_val: f.self_val)
            @current_block = nil
            @current_block_locals = nil
            # If dispatch pushed a new ScriptProc frame, do NOT push the
            # sentinel return value — Op::Ret will push the real result.
            push(result) if @frames.size == depth_before
          when Op::Ret
            result = pop
            # Drain locals back to stack_base
            f.stack_base.upto(@stack.size - 1) { @stack.pop } if @stack.size > f.stack_base
            pop_frame
            push(result) unless @frames.empty?

            # --- Arithmetic -----------------------------------------------------
          when Op::Add    then exec_binary(inst) { |lhs, rhs| ValueOps.add(lhs, rhs, error_raiser(f)) }
          when Op::Sub    then exec_binary(inst) { |lhs, rhs| ValueOps.op(lhs, rhs, :-, error_raiser(f)) }
          when Op::Mul    then exec_binary(inst) { |lhs, rhs| ValueOps.op(lhs, rhs, :*, error_raiser(f)) }
          when Op::Div    then exec_binary(inst) { |lhs, rhs| ValueOps.div(lhs, rhs, error_raiser(f)) }
          when Op::Mod    then exec_binary(inst) { |lhs, rhs| ValueOps.mod(lhs, rhs, error_raiser(f)) }
          when Op::BitAnd then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :&, error_raiser(f)) }
          when Op::BitOr  then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :|, error_raiser(f)) }
          when Op::Xor    then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :^, error_raiser(f)) }
          when Op::Shl    then exec_binary(inst) { |lhs, rhs| ValueOps.shl(lhs, rhs, error_raiser(f)) }
          when Op::Shr    then exec_binary(inst) { |lhs, rhs| ValueOps.int_op(lhs, rhs, :>>, error_raiser(f)) }
            # --- Comparison -----------------------------------------------------

          when Op::Eq
            b, a = pop, pop
            result = Value.bool(ValueOps.equal?(a, b), RiskFlowLabel.join(a.label, b.label))
            @risk_flow_log.record("Eq", [a.label, b.label], result.label, f.line)
            push(result)
          when Op::Lt  then exec_binary(inst) { |lhs, rhs| Value.bool(ValueOps.compare(lhs, rhs, :<)) }
          when Op::Lte then exec_binary(inst) { |lhs, rhs| Value.bool(ValueOps.compare(lhs, rhs, :<=)) }
          when Op::Gt  then exec_binary(inst) { |lhs, rhs| Value.bool(ValueOps.compare(lhs, rhs, :>)) }
          when Op::Gte then exec_binary(inst) { |lhs, rhs| Value.bool(ValueOps.compare(lhs, rhs, :>=)) }
            # --- Unary ----------------------------------------------------------

          when Op::Not
            push(Value.bool(pop.falsy?))
          when Op::Neg
            v = pop
            case
            when v.int?   then push(Value.int(-v.as_int))
            when v.float? then push(Value.float(-v.as_float))
            else               raise runtime_error("cannot negate #{v}", f)
            end
          when Op::BitNot
            v = pop
            raise runtime_error("~ requires Integer", f) unless v.int?
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
          when Op::Concat
            n = inst.a.to_i
            parts = @stack.last(n)
            @stack.pop(n) if n > 0
            str = parts.map { |part|
              case
              when part.string? then part.as_string
              when part.int?    then part.as_int.to_s
              when part.float?  then part.as_float.to_s
              when part.bool?   then part.as_bool.to_s
              when part.null?   then ""
              when part.symbol? then part.as_sym.name
              else                   part.to_s
              end
            }.join
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
          when Op::GetOuter
            slot = inst.c.to_i
            outer = f.outer_locals
            push(outer && slot < outer.size ? outer[slot] : Value.nil_value)
          when Op::SetOuter
            val = pop
            slot = inst.c.to_i
            outer = f.outer_locals
            outer[slot] = val if outer && slot < outer.size
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
              # research/IFC_DESIGN.md).
              push(make_lambda_object(sproc_val.as_proc, sproc_val.label, f.locals))
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
                raise runtime_error("uninitialized constant #{super_sym.name}", f)
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
            owner = f.self_val.as_rclass? || f.self_val.as_robject?.try(&.rclass)
            unless owner
              raise runtime_error("def outside of a class/module body", f)
            end
            proc = proc_val.as_proc
            proc.lexical_scope = owner
            owner.define_method(name_sym.value, proc)
            push(Value.nil_value)
          when Op::DefSingleton
            recv = pop
            proc_val = pop
            name_sym = chunk.consts[inst.c].as_sym
            # Same fix as Op::DefMethod above: `recv` (self at the
            # `def self.foo` site) may be a RubyObject (top-level
            # main, or `def self.foo` written inside an instance
            # method body), not just a bare RubyClass (the class/
            # module-body case).
            #
            # NOTE — approximation, not a full fix: real Ruby's
            # `def self.foo` on an INSTANCE defines a true per-object
            # singleton method (only that one object gets it, not
            # every instance of its class) — Adjutant has no
            # per-instance method table on RubyObject at all, only
            # RubyClass-level ones, so this targets the RECEIVER'S
            # CLASS instead, meaning every instance of that class
            # would see the new method, not just `recv`. This
            # happens to be observably correct for the motivating
            # case — top-level `def self.greet`, where self is
            # `main`, the ONE AND ONLY instance of Object a script
            # typically ever has as self — but is a real, separate
            # gap from true Ruby fidelity for the general "singleton
            # method on an arbitrary instance" case. Worth a proper
            # per-instance singleton table if that ever matters.
            owner = recv.as_rclass? || recv.as_robject?.try(&.rclass)
            unless owner
              raise runtime_error("def self.#{name_sym.name} outside of a class/module body", f)
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
              raise runtime_error("no block given", f)
            end
          when Op::BlockBreak
            val = pop
            # Unwind to the nearest non-block frame
            while !@frames.empty? && @frames.last.proc.is_block?
              sb = @frames.last.stack_base; (@stack.size - sb).times { @stack.pop } if @stack.size > sb
              pop_frame
            end
            push(val)

            # --- Exception handling ---------------------------------------
          when Op::Try
            raise runtime_error("internal error: unpatched Try target", f) if inst.c == Chunk::NO_TARGET
            f.handlers.push(HandlerEntry.new(rescue_ip: inst.c.to_i))
          when Op::SetEnsure
            raise runtime_error("internal error: unpatched SetEnsure target", f) if inst.c == Chunk::NO_TARGET
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
            # Pad or truncate to target count
            padded = Array(Value).new(tc) { |i| i < values.size ? values[i] : Value.nil_value }
            padded.each { |value| push(value) }
          when Op::GetMethodName
            push(Value.string(f.proc.name))
          else
            raise runtime_error("unknown opcode: #{inst.op}", f)
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
    protected def call_method(recv : Value, name : String, args : Array(Value),
                              filename : String = "<native>", line : Int32 = 0) : Value
      dispatch_call(name, [recv] + args, safe: false, filename: filename, line: line, has_receiver: true)
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

    # ameba:disable Metrics/CyclomaticComplexity - Clear steps, better together
    private def dispatch_call(name : String,
                              args : Array(Value),
                              safe : Bool,
                              filename : String, line : Int32,
                              blk : ScriptProc? = nil,
                              has_receiver : Bool = false,
                              blk_outer : Array(Value)? = nil,
                              self_val : Value? = nil) : Value
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
          return construct(recv.as_rclass, args[1..], filename, line, blk)
        end
        if recv.robject?
          cls = recv.as_robject.rclass
          if sym_id = @symbols.lookup(name).try(&.value)
            if method = cls.find_method(sym_id)
              return call_script_proc(method, args[1..], filename, blk, nil, self_val: recv, block_outer: blk_outer)
            end
            if native = cls.find_native_method(sym_id)
              return call_native(native, args, filename, line, blk, "#{cls.name}##{name}")
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
              return call_script_proc(method, args[1..], filename, blk, nil, self_val: recv, block_outer: blk_outer)
            end
            if native = cls.find_native_singleton_method(sym_id)
              return call_native(native, args, filename, line, blk, "#{cls.name}.#{name}")
            end
          end
        elsif interp = @interpreter
          # Builtin-typed receiver (Integer today; String/Array etc. as
          # they land) — no rclass of its own, resolved via
          # Interpreter#builtin_class_for instead.
          if (cls = interp.builtin_class_for(recv)) && (sym_id = @symbols.lookup(name).try(&.value))
            if native = cls.find_native_method(sym_id)
              return call_native(native, args, filename, line, blk, "#{cls.name}##{name}")
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
            # self is an ordinary object (main at top level, or any
            # instance inside its own method body) — its OWN class's
            # instance-method chain is exactly what a bare call means
            # here, same table an explicit `self.foo`/`obj.foo` would
            # use.
            cls = obj.rclass
            if method = cls.find_method(sym_id)
              return call_script_proc(method, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer)
            end
            if native = cls.find_native_method(sym_id)
              return call_native(native, args, filename, line, blk, display_name_for_implicit_self(name))
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
            #    bare Kernel-style native call (`puts`, or any
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
              return call_script_proc(singleton, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer)
            end
            if native_singleton = self_rclass.find_native_singleton_method(sym_id)
              return call_native(native_singleton, args, filename, line, blk, display_name_for_implicit_self(name))
            end
            if meta = self_rclass.rclass
              if method = meta.find_method(sym_id)
                return call_script_proc(method, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer)
              end
              if native = meta.find_native_method(sym_id)
                return call_native(native, args, filename, line, blk, display_name_for_implicit_self(name))
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
          return call_script_proc(sproc, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer)
        end
      end

      # 4) Built-in fallback operations
      if result = exec_builtin(name, args, filename, line, blk)
        return result
      end

      # No local, no native, no global proc, no builtin — this is an
      # unresolved bare identifier/method name. Real Ruby raises
      # NameError here (undefined local variable or method), so this
      # is script-catchable via `rescue NameError` (or `rescue`, since
      # NameError < StandardError) rather than silently returning nil.
      raise name_error("undefined method or variable: #{name}", filename, line)
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
                            filename : String, line : Int32, blk : ScriptProc?, name : String) : Value
      check_risk_flow(native, args, name, filename, line)
      NativeFunctionCall.new(self, native, filename, line, name).call(args, blk)
    rescue ex : RuntimeError
      raise ex
    rescue ex
      raise runtime_error("Native call error: #{ex.message}", current_frame, cause: ex)
    end

    # The risk flow check itself — see call_native's doc comment. A
    # no-op (cheap: one empty-tags check, no allocation) for the
    # overwhelming majority of native calls, which either have no
    # RiskTag at all (RiskProfile.none) or receive no labeled arguments.
    private def check_risk_flow(native : NativeCallable, args : Array(Value), name : String,
                                filename : String, line : Int32) : Nil
      return if native.risk.tags.empty?
      return unless args.any?(&.label)

      matches = [] of RiskFlowMatch
      native.risk.tags.each do |tag|
        args.each do |arg|
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
      msg = "risk flow policy rejected #{request.call_name}: #{reason}"
      cls = builtin_class_by_name("RiskFlowRejectedError")
      err_val = cls ? make_error_object(cls, msg) : Value.string(msg)
      raise RuntimeError.new(msg, filename, line, error_value: err_val)
    end

    # `Foo.new(args)` — dispatches to a native singleton `new` if the
    # class (or an ancestor) registered one via
    # RubyClass#define_native_singleton_method, otherwise falls back
    # to the generic script-`initialize` path. A native `new` is
    # responsible for its own allocation (typically a RubyObject
    # subclass carrying real state) and return value; the generic path
    # cannot express that, since it always allocates a bare
    # RubyObject.
    private def construct(cls : RubyClass, args : Array(Value), filename : String, line : Int32, blk : ScriptProc?) : Value
      raise runtime_error("can't instantiate module #{cls.name}") if cls.is_module?
      if sym_id = @symbols.lookup("new").try(&.value)
        if native_new = cls.find_native_singleton_method(sym_id)
          return call_native(native_new, [Value.rclass(cls)] + args, filename, line, blk, "#{cls.name}.new")
        end
      end
      construct_object(cls, args)
    end

    # The generic construction path: allocates a bare RubyObject and,
    # if the class (or an ancestor) defines `initialize`, runs it
    # synchronously via `invoke` so its return value can be discarded
    # and the object returned regardless of what `initialize` itself
    # returns.
    private def construct_object(cls : RubyClass, args : Array(Value)) : Value
      obj_val = Value.robject(RubyObject.new(cls))
      if sym_id = @symbols.lookup("initialize").try(&.value)
        if init = cls.find_method(sym_id)
          invoke(init, args, self_val: obj_val)
        end
      end
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
                                 outer : Array(Value)? = nil,
                                 self_val : Value? = nil,
                                 lexical_scope : RubyClass? = nil,
                                 lexical_override : Bool = false,
                                 block_outer : Array(Value)? = nil) : Value
      base = @stack.size
      inherited_self = self_val || (@frames.empty? ? Value.nil_value : current_frame.self_val)
      effective_lexical = if lexical_override
                            lexical_scope
                          else
                            proc.lexical_scope || (@frames.empty? ? nil : current_frame.lexical_scope)
                          end
      frame = push_frame(proc, filename, block: blk, stack_base: base, outer: outer, self_val: inherited_self,
        lexical_scope: effective_lexical, block_outer_locals: block_outer)
      args.each_with_index do |arg, i|
        frame.locals[i] = arg if i < frame.locals.size
      end
      Value.nil_value # sentinel; Op::Ret will push the real return value
    end

    # Minimal built-ins needed for specs to pass before stdlib lands.
    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_builtin(name : String,
                             args : Array(Value),
                             filename : String, line : Int32,
                             blk : ScriptProc? = nil) : Value?
      case name
      when "puts"
        str = args.map { |arg|
          case
          when arg.string? then arg.as_string
          when arg.null?   then ""
          when arg.bool?   then arg.as_bool.to_s
          when arg.int?    then arg.as_int.to_s
          when arg.float?  then arg.as_float.to_s
          when arg.symbol? then arg.as_sym.to_s
          else                  arg.to_s
          end
        }.join("\n")
        if ef = @effect
          ef.write_stdout(str + "\n")
        else
          STDOUT.puts(str)
        end
        Value.nil_value
      when "print"
        str = args.map(&.to_s).join
        if ef = @effect
          ef.write_stdout(str)
        else
          STDOUT.print(str)
        end
        Value.nil_value
      when "p"
        str = args.map(&.inspect).join("\n")
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
        cls, msg = if args.empty?
                     {builtin_class_by_name("RuntimeError"), "unhandled exception"}
                   elsif args.first.rclass?
                     raised_cls = args.first.as_rclass
                     {raised_cls, args[1]?.try(&.to_s) || raised_cls.name}
                   else
                     {builtin_class_by_name("RuntimeError"), args.first.to_s}
                   end
        err_val = cls ? make_error_object(cls, msg) : Value.string(msg)
        raise RuntimeError.new(msg, filename, line, error_value: err_val)
      when "==="
        a = args[0]? || Value.nil_value
        b = args[1]? || Value.nil_value
        Value.bool(values_equal?(a, b))
      when "require"
        path = args.first? ? args.first.as_string : ""
        if interp = @interpreter
          interp.require_module(path, filename)
        else
          raise RuntimeError.new("'require' cannot load -- #{path} (no interpreter)", filename, line)
        end
      when "nil?"
        # Called as a method: args[0] is receiver
        recv = args.first? || Value.nil_value
        Value.bool(recv.null?)
      when "message"
        # Called as a method on an error object (or any RubyObject with
        # a message ivar). Falls back to the class name if unset, or
        # to_s for non-RubyObject receivers.
        recv = args.first? || Value.nil_value
        if obj = recv.as_robject?
          msg_sym = @symbols.intern("message")
          obj.ivars[msg_sym.value]? || Value.string(obj.rclass.name)
        else
          Value.string(recv.to_s)
        end
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
      when "to_s"
        recv = args.first? || Value.nil_value
        Value.string(recv.to_s)
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
    # implementation (NativeFunctionCall, in interpreter.cr) delegates
    # to `@vm.compare`/`@vm.values_equal?` by name — the delegation
    # contract stays the same, the logic behind it moved.

    protected def compare(a : Value, b : Value, op : Symbol) : Bool
      ValueOps.compare(a, b, op)
    end

    protected def values_equal?(a : Value, b : Value) : Bool
      ValueOps.equal?(a, b)
    end

    # --- Index helpers ------------------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_get_index(target : Value, idx : Value, safe : Bool) : Value
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
        (i >= 0 && i < s.size) ? Value.string(s[i].to_s) : Value.nil_value
      else
        Value.nil_value
      end
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
    # script-catchable error object (a real RuntimeError RubyObject,
    # not just a message string) is still built in exactly one place.
    private def error_raiser(frame : Frame) : ValueOps::OnError
      ->(msg : String) { raise runtime_error(msg, frame) }
    end

    private def runtime_error(msg : String, frame : Frame = current_frame, cause = nil) : RuntimeError
      cls = builtin_class_by_name("RuntimeError")
      err_val = cls ? make_error_object(cls, msg) : nil
      RuntimeError.new(msg, frame, cause, error_value: err_val)
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
        raise runtime_error("Range class not registered — bootstrap_builtin_classes must run before any Range literal is evaluated")
      end
      obj = RubyObject.new(cls)
      obj.ivars[@symbols.intern("__min").value] = rstart
      obj.ivars[@symbols.intern("__max").value] = rend
      obj.ivars[@symbols.intern("__exclusive").value] = Value.bool(exclusive)
      Value.robject(obj, label)
    end

    # Wraps a ScriptProc (already built by the compiler for a Lambda
    # node — see compile_lambda) in a real Proc RubyObject. See
    # builtins/proc.cr and SCOPE.md Piece C: only Lambda-node output
    # goes through this; call-site block literals and def bodies keep
    # using the bare sproc Value directly (Op::MakeProc with a=0),
    # never reach here.
    private def make_lambda_object(sproc : ScriptProc, label : RiskFlowLabel?, outer_locals : Array(Value)?) : Value
      cls = builtin_class_by_name("Proc")
      unless cls
        raise runtime_error("Proc class not registered — bootstrap_builtin_classes must run before any lambda literal is evaluated")
      end
      obj = RubyObject.new(cls)
      obj.ivars[@symbols.intern("__sproc").value] = Value.proc(sproc)
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
