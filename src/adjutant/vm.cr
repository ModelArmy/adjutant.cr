require "./bytecode"
require "./symbol_table"
require "./value"
require "./value_ops"
require "./ast"
require "./risk_flow_policy"
require "./risk_flow_decision"
require "./builtins/regexp"
require "./fatal_signal"

module Adjutant
  # A compiled method, lambda or block body, storable as a Value.
  class ScriptProc
    getter chunk : Chunk
    getter name : String
    getter params : Array(String)
    getter local_count : Int32
    getter? is_block : Bool

    # The AST the proc was compiled from, nil when there is none.
    # `ast_body` is read only by RiskWalker; `ast_params` by
    # `VM#bind_args` for defaults, splats and keywords.
    getter ast_body : Body?
    getter ast_params : Array(Param)?

    # For a block, the method it was written in, named by R007's
    # message instead of `<block>`.
    getter home_method : String?

    # The class or module the proc was defined in, set by DefMethod.
    # Nil for top-level methods and for blocks.
    property lexical_scope : RubyClass?

    def initialize(@chunk, @name, @params = [] of String, @local_count = 0, @is_block = false,
                   @ast_body = nil, @ast_params = nil, @home_method = nil)
    end
  end

  # The pending rescue and ensure targets of one begin/rescue/ensure
  # construct while its body runs. One entry holds both, so entries
  # from different constructs unwind in the order they were entered.
  class HandlerEntry
    property rescue_ip : Int32?
    property ensure_ip : Int32?

    def initialize(@rescue_ip = nil, @ensure_ip = nil)
    end
  end

  # A closure's enclosing scopes, nearest first: depth 0 is the frame
  # that created the closure. Each entry is that frame's own `locals`
  # array, not a copy, so writes reach the real variable.
  alias OuterChain = Array(Array(Value))

  class Frame
    getter proc : ScriptProc
    getter chunk : Chunk
    property ip : Int32
    property line : Int32
    property stack_base : Int32
    getter filename : String
    property block : ScriptProc?
    # Begin constructs open in this frame, innermost last. Try (or
    # SetEnsure, for an ensure-only construct) pushes; SetEnsure adds
    # its target to the entry Try just pushed; EndTry clears the rescue
    # target; EnterEnsure pops the entry.
    getter handlers : Array(HandlerEntry)

    # Local variable slots, sized from `ScriptProc#local_count`.
    getter locals : Array(Value)

    # For a block or lambda frame, the enclosing scopes it closes
    # over; nil for a method frame.
    property outer_locals : OuterChain?

    # `self` in this frame: the receiver in a method, the class or
    # module in its body, `main` at top level.
    property self_val : Value

    # The class or module for constant lookup. A method frame takes
    # its proc's; a block frame takes its caller's.
    property lexical_scope : RubyClass?

    # The scopes the block passed to this call closes over, captured
    # by SetBlock where the block was written. `yield` gives them to
    # the block as its `outer_locals`. Nil when no block was passed.
    property block_outer_locals : OuterChain?

    # `yield`'s target in the two cases `@block` can't give it.
    # `block_yield` is the yield target of the method the attached
    # block was written in, captured by SetBlock and handed on when
    # this frame yields. `own_yield` is that target once received:
    # what `yield` means inside a block frame.
    property block_yield : ScriptProc?
    property own_yield : ScriptProc?

    # The closure scopes to run each yield target with, carried
    # alongside it.
    property block_yield_outer : OuterChain?
    property own_yield_outer : OuterChain?

    # How many positional arguments the call passed, for GetArgc.
    # `locals.size` counts declared slots instead.
    property argc : Int32

    # The keyword argument names the call passed, for HasKwarg; nil
    # when it passed none.
    property kwarg_names : Set(String)?

    # What `yield` resolves to in this frame: a method's own block, or
    # for a block frame the block of the method it was written in.
    # Ruby resolves `yield` lexically, so `items.each { |x| yield x }`
    # reaches the enclosing method's block rather than finding none.
    def yield_target : ScriptProc?
      @proc.is_block? ? @own_yield : @block
    end

    # The closure context to invoke `yield_target` with.
    def yield_outer : OuterChain?
      @proc.is_block? ? @own_yield_outer : @block_outer_locals
    end

    def initialize(@proc, @chunk, @stack_base, @filename, @block = nil, outer : OuterChain? = nil,
                   @self_val : Value = Value.nil_value, @lexical_scope : RubyClass? = nil,
                   @block_outer_locals : OuterChain? = nil, @argc : Int32 = 0,
                   @block_yield : ScriptProc? = nil, @own_yield : ScriptProc? = nil,
                   @block_yield_outer : OuterChain? = nil, @own_yield_outer : OuterChain? = nil)
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
    # The error object a script rescues, when one was built;
    # otherwise the error is represented by `message`.
    getter error_value : Value?

    # The structured report of a failure Adjutant classified. Nil for
    # an error the script raised itself (`raise "boom"`, a re-raise),
    # whose message belongs to the script's author; keep it nilable.
    # `error_value` is what the script rescues; this is what the host
    # reads.
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

    # For errors raised with no frame, such as a failed `require`.
    def initialize(diagnostic : Diagnostic, @filename : String, @line : Int32,
                   cause = nil, @error_value = nil)
      @diagnostic = diagnostic
      super(diagnostic.to_line, cause)
    end
  end

  # Unwinds a `break` from a block to the native call running the
  # block, `VM#call_native`, the only place that rescues it. The
  # innermost native call catches it, so in
  # `outer.each { inner.each { break } }` only the inner `each` ends.
  # Not a RuntimeError, so no script `rescue` can catch it.
  class BlockBreakSignal < Exception
    getter value : Value

    def initialize(@value)
      super("break outside call_native — internal, should never surface to a script")
    end
  end

  # The bytecode VM: one instance per script execution, holding the
  # value stack, frames, globals and execution state.
  class VM
    MAX_STACK = 4096

    # An empty chunk for the sentinel frame `call_method` runs under,
    # which carries a filename and line but no code. Never mutated, so
    # one instance is shared.
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
      # The closure scopes of `@current_block`, captured by SetBlock
      # and passed to the callee as `Frame#block_outer_locals`.
      @current_block_locals = nil.as(OuterChain?)
      @current_block_yield = nil.as(ScriptProc?)
      @current_block_yield_outer = nil.as(OuterChain?)
      # Keyword arguments staged by SetKwargNames for the next Call,
      # which clears them. Nil when the call has none.
      @pending_kwargs = nil.as(Hash(String, Value)?)
      # The most recently caught error, for PushError: an error object,
      # or a message string when none was built.
      @last_error = Value.nil_value
      # The error an ensure body was entered with, re-raised by
      # EndEnsure. An error raised inside the ensure body supersedes
      # it, as in Ruby. Cleared on every fresh catch.
      @pending_reraise = nil.as(Value?)
      # Containers being rendered, for `guard_rendering`. VM-wide,
      # since a recursive `inspect` re-enters the VM at each level.
      @rendering_ids = Set(UInt64).new
    end

    # Runs a compiled top-level chunk and returns its value.
    def run(chunk : Chunk, filename : String = "<script>", local_count : Int32 = 0) : Value
      # A host wiring error, not a RuntimeError: no script is running
      # to rescue it.
      unless @frames.empty?
        raise HostStateError.new(Diagnostic.new(code: "H005"))
      end
      main_proc = ScriptProc.new(chunk, "<main>", local_count: local_count)
      # Top-level self is `main`, an Object, as in Ruby. A VM built
      # without an Interpreter has no Object class, so uses nil, and a
      # top-level `def` there has nothing to attach to.
      self_val = @interpreter.try { |i| Value.robject(i.main) } || Value.nil_value
      push_frame(main_proc, filename, self_val: self_val)
      execute
    end

    # Runs a block passed to a native function (its `blk`), closing
    # over the current frame. That frame is the block's defining frame,
    # since a block is only run during the call that received it; if
    # blocks could ever be captured (U001), this would no longer hold.
    # For a stored Proc, use `invoke_proc`.
    protected def invoke(proc : ScriptProc, args : Array(Value), self_val : Value? = nil,
                         kwargs : Hash(String, Value)? = nil) : Value
      invoke_internal(proc, spread_block_args(proc, args, kwargs), self_val, outer_locals: nil, kwargs: kwargs)
    end

    # Runs a stored Proc object with the closure it captured. Raises
    # H004 if `proc_obj` is not a Proc.
    protected def invoke_proc(proc_obj : RubyObject, args : Array(Value), self_val : Value? = nil) : Value
      unless proc_obj.rclass == builtin_class_by_name("Proc")
        # H004, not an I code: the caller is a host native function
        # passing the wrong value. It reaches the reader as N001
        # through `call_native`, which names the failing function.
        raise HostArgumentError.new(
          Diagnostic.new(code: "H004", data: {"found" => proc_obj.rclass.name})
        )
      end
      sproc = proc_obj.ivars[@symbols.intern("__sproc").value].as_proc
      invoke_internal(sproc, args, self_val, outer_locals: proc_obj.outer_locals)
    end

    # Returns a live block as a Proc object closing over the current
    # frame, as `->(){}` at the same spot would; `lambda { }` uses it.
    # The Proc gets no label of its own.
    protected def wrap_block_as_proc(blk : ScriptProc, filename : String, line : Int32) : Value
      f = current_frame
      make_lambda_object(blk, nil, [f.locals] + (f.outer_locals || [] of Array(Value)), filename, line)
    end

    # Runs `proc` in an isolated frame and value stack and returns its
    # result. `outer_locals` is the closure to run it with, or nil for
    # the current frame and the scopes it closes over.
    private def invoke_internal(proc : ScriptProc, args : Array(Value), self_val : Value? = nil,
                                outer_locals : OuterChain? = nil, kwargs : Hash(String, Value)? = nil) : Value
      saved_frames = @frames
      saved_stack = @stack
      saved_ins_count = @instruction_count
      saved_cur_block = @current_block
      saved_cur_block_locals = @current_block_locals
      saved_cur_block_yield = @current_block_yield
      saved_cur_block_yield_outer = @current_block_yield_outer
      saved_pending_kwargs = @pending_kwargs
      begin
        f = current_frame # before replacing @frames
        inherited_self = self_val || f.self_val
        inherited_lexical = proc.lexical_scope || f.lexical_scope
        # The current frame plus its own enclosing scopes, so a block
        # run inside another block reaches both.
        effective_outer = outer_locals || ([f.locals] + (f.outer_locals || [] of Array(Value)))
        @frames = [] of Frame
        # A fresh value stack as well as a fresh frame list: Ret
        # pushes its result only when frames remain, so with shared
        # stacks a nested call would return whatever the caller had
        # on top, such as a half-built array literal's element.
        @stack = Array(Value).new(256)
        # A block run by a native method yields to what its defining
        # frame would, since that frame's call is still in progress.
        call_script_proc(proc, args, f.filename, nil, effective_outer, self_val: inherited_self,
          lexical_scope: inherited_lexical, lexical_override: true, kwargs: kwargs,
          own_yield: f.yield_target, own_yield_outer: f.yield_outer)
        result = execute
      ensure
        @frames = saved_frames
        @stack = saved_stack
        @instruction_count = saved_ins_count
        @current_block = saved_cur_block
        @current_block_locals = saved_cur_block_locals
        @current_block_yield = saved_cur_block_yield
        @current_block_yield_outer = saved_cur_block_yield_outer
        @pending_kwargs = saved_pending_kwargs
      end
      result
    end

    # Sets the global `name`.
    def set_global(name : String, value : Value) : Nil
      sym = @symbols.intern(name)
      @globals[sym.value] = value
    end

    # Whether `recv` is an instance of `target` or of a class that
    # inherits from or includes it. For a class receiver the chain
    # starts at its class: `Integer.is_a?(Class)` is true.
    private def is_a_target?(recv : Value, target : RubyClass?) : Bool
      start_cls = recv.as_robject?.try(&.rclass) ||
                  recv.as_rclass?.try(&.rclass) ||
                  @interpreter.try(&.builtin_class_for(recv))
      return false unless start_cls && target
      cls = start_cls.as(RubyClass?)
      while cls
        return true if cls == target
        # Direct includes only; a module included by an included
        # module is missed.
        return true if cls.included_modules.includes?(target)
        cls = cls.superclass
      end
      false
    end

    # Whether `v` is a Range instance, by class, not by its ivars.
    private def range_receiver?(v : Value) : Bool
      obj = v.as_robject?
      !!(obj && obj.rclass == builtin_class_by_name("Range"))
    end

    # Range#===: `min <= x` and `x < max` (or `x <= max` for an
    # inclusive range), through `compare` so a custom `<=>` applies. A
    # nil bound is satisfied without comparing. The `__min`, `__max`
    # and `__exclusive` ivars must match `make_range_object` and
    # `builtins/range.cr`.
    private def range_include?(range : Value, x : Value) : Bool
      obj = range.as_robject
      min = obj.ivars[@symbols.intern("__min").value]
      max = obj.ivars[@symbols.intern("__max").value]
      exclusive = obj.ivars[@symbols.intern("__exclusive").value].as_bool
      return false unless min.null? || compare(x, min, :>=)
      return true if max.null?
      exclusive ? compare(x, max, :<) : compare(x, max, :<=)
    end

    # Whether `v` is a Proc instance, by class, not by its ivars.
    private def proc_receiver?(v : Value) : Bool
      obj = v.as_robject?
      !!(obj && obj.rclass == builtin_class_by_name("Proc"))
    end

    # Ruby's `pattern === subject`, for TripleEq, which bare `a === b`
    # and `case`/`when` both compile to. Not method dispatch: `===` is
    # fixed, like `==`, so a new type's matching rule is a branch here.
    # So `/re/.===(s)`, like `a.==(b)`, is an undefined method.
    private def triple_eq_matches?(pattern : Value, subject : Value) : Bool
      if cls = pattern.as_rclass?
        # `Class#===`: is `subject` an instance of it.
        is_a_target?(subject, cls)
      elsif range_receiver?(pattern)
        # `Range#===`: is `subject` within the bounds.
        range_include?(pattern, subject)
      elsif (robj = pattern.as_robject?) && robj.is_a?(RegexpObject)
        # `Regexp#===`: does the pattern match `subject`.
        str = subject.as_string?
        str ? robj.regex.matches?(str) : false
      elsif proc_receiver?(pattern)
        # `Proc#===`: the truthiness of calling it with `subject`, as
        # in `when ->(x) { x.even? }`.
        invoke_proc(pattern.as_robject, [subject]).truthy?
      else
        # Anything else: `==`, as Ruby's `Object#===` is.
        values_equal?(subject, pattern)
      end
    end

    # `String#[range]`, by Ruby's rules for Integer bounds: negative
    # bounds count from the end, a start past the end gives nil, a
    # start at the end gives "", and a late end is clamped. Returns nil
    # for any other bound, including a missing one (`s[1..]`).
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

    # Whether `recv` has `method_name`, in the order `dispatch_call`
    # resolves it, without calling it.
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

    # The class whose cvars `f` reads: self's class for an instance,
    # self for a class or module body. Raises outside a class context,
    # as Ruby does.
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

    # Reads `@name` from `self`: an object's ivars, or a class's own
    # class-level ivars. Nil when unset, or when self is neither.
    private def read_ivar(self_val : Value, sym_id : Int32) : Value
      if obj = self_val.as_robject?
        return obj.ivars[sym_id]? || Value.nil_value
      end
      if cls = self_val.as_rclass?
        return cls.get_ivar(sym_id) || Value.nil_value
      end
      Value.nil_value
    end

    # Writes `@name` to `self`, as `read_ivar` reads it. Does nothing
    # when self is neither an object nor a class.
    private def write_ivar(self_val : Value, sym_id : Int32, val : Value) : Nil
      if obj = self_val.as_robject?
        obj.ivars[sym_id] = val
        return
      end
      if cls = self_val.as_rclass?
        cls.set_ivar(sym_id, val)
      end
    end

    # The method a `yield` belongs to, for R007: for a block frame,
    # the method the block was written in.
    private def yielding_method_name(f : Frame) : String
      return f.proc.name unless f.proc.is_block?
      # Recorded by the compiler: a block run by a native method has
      # no frame for its method on this frame stack.
      f.proc.home_method || f.proc.name
    end

    private def push_frame(proc : ScriptProc, filename : String, block : ScriptProc? = nil, stack_base : Int32 = @stack.size,
                           outer : OuterChain? = nil, self_val : Value = Value.nil_value, lexical_scope : RubyClass? = nil,
                           block_outer_locals : OuterChain? = nil, argc : Int32 = 0,
                           block_yield : ScriptProc? = nil, own_yield : ScriptProc? = nil,
                           block_yield_outer : OuterChain? = nil, own_yield_outer : OuterChain? = nil) : Frame
      if @limits.call_depth_limit > 0 && @frames.size >= @limits.call_depth_limit
        raise script_diagnostic("L002", {"limit" => @limits.call_depth_limit.to_s}, current_frame)
      end
      frame = Frame.new(proc, proc.chunk, stack_base, filename, block, outer, self_val, lexical_scope, block_outer_locals, argc,
        block_yield, own_yield, block_yield_outer, own_yield_outer)
      @frames.push(frame)
      frame
    end

    private def pop_frame : Frame
      @frames.pop
    end

    private def current_frame : Frame
      @frames.last
    end

    # `self` in the current frame, which for a native function is the
    # calling frame. For calls with an implicit receiver, such as
    # `include Foo` in a class body, whose `args` carry none.
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
              # A global's value: a class, or a name a block
              # assigned.
              push(gval)
            else
              # Not a local or global: an implicit zero-argument call
              # on self (a top-level `def` is a method of Object), then
              # native functions and builtins, else NameError.
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
            # Ivars belong to self: an object's ivars, or a class's
            # class-level ivars, which are separate slots. Cvars belong
            # to self's class and are found up the superclass chain;
            # outside a class context they raise.

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
            # Looked up in the enclosing class or module (self in a
            # class body, else the proc's lexical scope), then at top
            # level.

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
            # Reassigning a constant raises, where Ruby only warns.
            # A stricter rule, so a subset: the risk walker can trust
            # a constant's value. Top-level constants live in
            # `@globals`; those in a class or module body in its
            # `constants`.
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
            # The stack is `[value, target, index]`: the value was
            # pushed first, the reverse of SetIndex.
            idx = pop
            target = pop
            val = pop
            exec_set_index(target, idx, val)
            @risk_flow_log.record("SetIndexFromValue", [target.label, val.label], target.label, f.line)
            push(val)
          when Op::SetAttr
            # `call_method` runs a script setter to completion here,
            # so its return value can be discarded for `val`.
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
            # The block closes over this frame and the scopes this
            # frame closes over, captured now, before the callee runs.
            @current_block_locals = @current_block ? [f.locals] + (f.outer_locals || [] of Array(Value)) : nil
            # Captured here, not read at yield time: the block's target
            # is the one in force where it was written.
            @current_block_yield = @current_block ? f.yield_target : nil
            @current_block_yield_outer = @current_block ? f.yield_outer : nil
          when Op::SetKwargNames
            # `@stack.last(n)` is in push order, so the pairs read as
            # (name, value). Each value keeps its own label; nothing
            # new is built, so nothing is logged.
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
            # `ensure` clears the staged block and keywords even if the
            # call raises; otherwise the next Call would inherit them,
            # such as a rescue clause's `is_a?` test failing with R012.
            result = begin
              dispatch_call(sym.name, args, safe, f.filename, inst.line, @current_block, has_receiver,
                blk_outer: @current_block_locals, self_val: f.self_val, kwargs: @pending_kwargs,
                blk_yield: @current_block_yield, blk_yield_outer: @current_block_yield_outer)
            ensure
              @current_block = nil
              @current_block_locals = nil
              @current_block_yield = nil
              @current_block_yield_outer = nil
              @pending_kwargs = nil
            end
            # A script method pushed a frame; its Ret pushes the
            # result.
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
            # Drops this frame's leftover stack values.
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
          when Op::Lt       then exec_binary(inst) { |lhs, rhs| Value.bool(strict_compare(lhs, rhs, :<)) }
          when Op::Lte      then exec_binary(inst) { |lhs, rhs| Value.bool(strict_compare(lhs, rhs, :<=)) }
          when Op::Gt       then exec_binary(inst) { |lhs, rhs| Value.bool(strict_compare(lhs, rhs, :>)) }
          when Op::Gte      then exec_binary(inst) { |lhs, rhs| Value.bool(strict_compare(lhs, rhs, :>=)) }
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
            # Unary `+` on an Integer or Float returns it unchanged, and
            # raises on anything else, like Neg.
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
              # The lambda closes over this frame and the scopes this
              # frame closes over, captured where it is written.
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
            # A class with no `<` inherits from Object. Nil only for a
            # VM built without an Interpreter.
            superclass ||= @interpreter.try(&.object_class)
            new_cls = RubyClass.new(name_sym.name, superclass, is_module: false)
            new_cls.rclass = @interpreter.try(&.class_class)
            new_cls.lexical_parent = f.self_val.as_rclass?
            push(Value.rclass(new_cls))
          when Op::MakeModule
            name_sym = chunk.consts[inst.c].as_sym
            new_mod = RubyClass.new(name_sym.name, nil, is_module: true)
            # A module's class is Class, as in Ruby.
            new_mod.rclass = @interpreter.try(&.class_class)
            new_mod.lexical_parent = f.self_val.as_rclass?
            push(Value.rclass(new_mod))
          when Op::DefMethod
            proc_val = pop
            name_sym = chunk.consts[inst.c].as_sym
            # `def` defines on self's class: self itself in a class or
            # module body, otherwise self's class, so a top-level `def`
            # becomes a method of Object.
            owner_rclass = f.self_val.as_rclass?
            owner = owner_rclass || f.self_val.as_robject?.try(&.rclass)
            unless owner
              raise script_diagnostic("R006", {"definition" => "def #{name_sym.name}"}, f)
            end
            proc = proc_val.as_proc
            proc.lexical_scope = owner
            # A `def` run with an object as self can only be at top
            # level, since the compiler rejects nested defs, so it is
            # private, as in Ruby: callable bare or as `self.hello`,
            # not with another receiver.
            owner.define_method(name_sym.value, proc, is_private: owner_rclass.nil?)
            push(Value.nil_value)
          when Op::DefSingleton
            recv = pop
            proc_val = pop
            name_sym = chunk.consts[inst.c].as_sym
            # `recv` is a class or module, or `main` at top level;
            # `def self.foo` inside a method is rejected by the
            # compiler.
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
            blk = f.yield_target
            if blk
              depth_before = @frames.size
              # The block closes over where it was written, not this
              # frame.
              result = call_script_proc(blk, spread_block_args(blk, args), f.filename, nil, f.yield_outer,
                own_yield: f.block_yield, own_yield_outer: f.block_yield_outer)
              push(result) if @frames.size == depth_before
            else
              raise script_diagnostic("R007", {"method" => yielding_method_name(f)}, f)
            end
          when Op::BlockBreak
            val = pop
            # Pops consecutive block frames, remembering the outermost,
            # which `yield` pushed if the break came through one.
            last_popped_proc = nil.as(ScriptProc?)
            while !@frames.empty? && @frames.last.proc.is_block?
              sb = @frames.last.stack_base; (@stack.size - sb).times { @stack.pop } if @stack.size > sb
              last_popped_proc = @frames.last.proc
              pop_frame
            end
            if @frames.empty?
              # No frames left: the block was run by a native method
              # (`invoke_internal`). The nearest `call_native` catches
              # the signal, and `invoke_internal` restores the outer
              # frames.
              raise BlockBreakSignal.new(val)
            elsif last_popped_proc && @frames.last.block == last_popped_proc
              # This frame yielded to the block, so the break ends its
              # call, as in Ruby: pop it, as Ret does, and push the
              # value to its caller.
              landed = @frames.last
              (@stack.size - landed.stack_base).times { @stack.pop } if @stack.size > landed.stack_base
              pop_frame
              push(val) unless @frames.empty?
            else
              # A `break` outside any loop or block pushes its value and
              # carries on. Ruby raises LocalJumpError.
              push(val)
            end

            # --- Exception handling ---------------------------------------
          when Op::Try
            raise internal_diagnostic("I002", {"target" => "Try"}, f) if inst.c == Chunk::NO_TARGET
            f.handlers.push(HandlerEntry.new(rescue_ip: inst.c.to_i))
          when Op::SetEnsure
            raise internal_diagnostic("I002", {"target" => "SetEnsure"}, f) if inst.c == Chunk::NO_TARGET
            if inst.b == 1_u16
              # The same construct as the Try just before: add to its
              # entry.
              if top = f.handlers.last?
                top.ensure_ip = inst.c.to_i
              end
            else
              f.handlers.push(HandlerEntry.new(ensure_ip: inst.c.to_i))
            end
          when Op::EndTry
            clear_rescue_portion(f)
          when Op::EnterEnsure
            # Removes this construct's handler entry, however the
            # ensure was reached.
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
            # The caught error: an error object, or a message string.
            push(@last_error)
            # --- Misc -----------------------------------------------------------

          when Op::MultiUnpack
            tc = inst.a.to_i
            vc = inst.b.to_i
            values = @stack.last(vc)
            @stack.pop(vc) if vc > 0
            # One Array value spreads across several targets, as in
            # Ruby: `a, b = [1, 2]` splats; `a, b = [1, 2], 3` doesn't.
            values = values[0].as_array.to_a if vc == 1 && tc > 1 && values[0].array?
            # Pads with nil or drops extras to match the targets.
            padded = Array(Value).new(tc) { |i| i < values.size ? values[i] : Value.nil_value }
            padded.each { |value| push(value) }
          when Op::GetMethodName
            push(Value.string(f.proc.name))
          else
            raise internal_diagnostic("I001", {"opcode" => inst.op.to_s}, f)
          end
        rescue ex : RuntimeError
          # A new error supersedes any re-raise still pending.
          @pending_reraise = nil

          # Unwinds frames to the innermost handler, in this frame or a
          # caller. Within an entry the rescue target is tried before the
          # ensure target, so a more nested construct always wins.
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
                # Pops the entry too when it has no ensure, as EndTry
                # does.
                clear_rescue_portion(candidate)
                found_on_this_frame = true
                break
              elsif eip = top.ensure_ip
                handler_frame = candidate
                handler_ip = eip
                entering_ensure = true
                # EnterEnsure pops the entry.
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
              # EndEnsure re-raises this once the ensure body ends. An
              # error raised in the ensure body supersedes it.
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

    # Calls `recv.name(*args)` from native code and returns the
    # result, as `x.name(...)` in a script would. A script method runs
    # to completion in isolated frames and stack, as in
    # `invoke_internal`; a native one returns directly.
    protected def call_method(recv : Value, name : String, args : Array(Value),
                              filename : String = "<native>", line : Int32 = 0) : Value
      saved_frames = @frames
      saved_stack = @stack
      saved_ins_count = @instruction_count
      saved_cur_block = @current_block
      saved_cur_block_locals = @current_block_locals
      saved_cur_block_yield = @current_block_yield
      saved_cur_block_yield_outer = @current_block_yield_outer
      saved_pending_kwargs = @pending_kwargs
      # A sentinel frame gives `current_frame` a filename and line for
      # diagnostics if nothing resolves; its empty chunk ends
      # `execute`'s loop.
      sentinel = Frame.new(SENTINEL_PROC, SENTINEL_CHUNK, 0, filename)
      sentinel.line = line
      @frames = [sentinel]
      @stack = Array(Value).new(256)
      begin
        result = dispatch_call(name, [recv] + args, safe: false, filename: filename, line: line, has_receiver: true)
        # A native result is complete. A script method pushed a frame,
        # which `execute` runs; its result comes back through
        # `execute`'s `@stack.last? || result` fallback, since Ret
        # doesn't push while the sentinel remains.
        @frames.size <= 1 ? result : execute
      ensure
        @frames = saved_frames
        @stack = saved_stack
        @instruction_count = saved_ins_count
        @current_block = saved_cur_block
        @current_block_locals = saved_cur_block_locals
        @current_block_yield = saved_cur_block_yield
        @current_block_yield_outer = saved_cur_block_yield_outer
        @pending_kwargs = saved_pending_kwargs
      end
    end

    # The name an implicit-self call shows in errors and risk-flow
    # requests: as written, `delete_file`, not `Object#delete_file`.
    private def display_name_for_implicit_self(name : String) : String
      name
    end

    # Runs a `super` call. The method name is the current frame's.
    # Resolution searches self's ancestors (or singleton ancestors,
    # for a class method) after the current method's lexical scope,
    # so an included module between a class and its superclass is
    # found. self is unchanged. A proc with no lexical scope finds
    # nothing.
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

      # From self's own class, which may be a subclass of where this
      # method is defined. A class-method `super` is the branch below.
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
        # The singleton side: each entry says whether to search its
        # singleton table (self and superclasses) or its instance table
        # (extended modules).
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

      # NoMethodError, as Ruby: "super: no superclass method".
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R014",
          primary: Span.new(line: line, filename: filename),
          data: {"method" => name}
        ),
        error_class: "NoMethodError"
      )
    end

    # Calls the script method `super` found, forwarding the current
    # self and block.
    private def call_script_method(method : ScriptProc, call_args : Array(Value), call_kwargs : Hash(String, Value)?,
                                   f : Frame, filename : String) : Value
      # The current method's block is passed on, as in Ruby, with
      # the closure it was attached with.
      call_script_proc(method, call_args, filename, f.block,
        self_val: f.self_val, block_outer: f.block_outer_locals, kwargs: call_kwargs,
        block_yield: f.block_yield, block_yield_outer: f.block_yield_outer)
    end

    # Calls the native method `super` found on `candidate`.
    private def call_super_native(native : NativeCallable, call_args : Array(Value), call_kwargs : Hash(String, Value)?,
                                  f : Frame, filename : String, line : Int32, candidate : RubyClass, name : String) : Value
      # Native methods take the receiver as `args.first`.
      call_native(native, [f.self_val] + call_args, filename, line, f.block, "#{candidate.name}##{name}", kwargs: call_kwargs)
    end

    # The arguments bare `super` forwards: each parameter's current
    # value, in declared order. A splat's elements go as separate
    # arguments, keywords as keywords. A proc with no `ast_params`
    # forwards nothing.
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

    # Raises R023 (NoMethodError) if the method `sym_id` resolved to
    # on `cls` is private and the receiver is not self at the call
    # site. By identity, so `self.hello` is allowed, as in Ruby.
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

    # A value's `to_s`, as `puts`, `print` and interpolation render it.
    # Objects, Arrays, Hashes, and classes with their own `to_s`
    # dispatch to it; other values can't override it (U003), so render
    # directly.
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

    # A value's `inspect`, dispatched as for `render_to_s`.
    private def render_inspect(value : Value, filename : String, line : Int32) : String
      if value.robject? || value.array? || value.hash? ||
         (value.rclass? && rclass_override?(value.as_rclass, "inspect"))
        call_method(value, "inspect", [] of Value, filename, line).as_string
      else
        value.inspect
      end
    end

    # Whether `cls` defines its own singleton `name`. Checked before
    # dispatching, so an override's own exception propagates. Without
    # one, the default rendering applies.
    private def rclass_override?(cls : RubyClass, name : String) : Bool
      sym_id = @symbols.lookup(name).try(&.value)
      return false unless sym_id
      !!(cls.find_singleton_method(sym_id) || cls.find_native_singleton_method(sym_id))
    end

    # See `NativeCallContext#guard_rendering`.
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
                              kwargs : Hash(String, Value)? = nil,
                              blk_yield : ScriptProc? = nil,
                              blk_yield_outer : OuterChain? = nil) : Value
      # 1. Safe navigation: a nil receiver skips the call.
      if safe && !args.empty? && args.first.null?
        return Value.nil_value
      end

      # 2. An explicit receiver: its own methods and `.new`, ahead of
      # functions of the same name.
      if has_receiver && !args.empty?
        recv = args.first
        if recv.rclass? && name == "new"
          # Keywords reach a script `initialize` through `bind_args`.
          # A native `new` without `kwarg_names`, or a class without
          # `initialize`, rejects them (R012).
          return construct(recv.as_rclass, args[1..], filename, line, blk, kwargs: kwargs)
        end
        if recv.robject?
          cls = recv.as_robject.rclass
          if sym_id = @symbols.lookup(name).try(&.value)
            if method = cls.find_method(sym_id)
              raise_if_private_call(cls, sym_id, name, recv, self_val, filename, line, native: false)
              return call_script_proc(method, args[1..], filename, blk, nil, self_val: recv, block_outer: blk_outer, kwargs: kwargs, block_yield: blk_yield, block_yield_outer: blk_yield_outer)
            end
            if native = cls.find_native_method(sym_id)
              raise_if_private_call(cls, sym_id, name, recv, self_val, filename, line, native: true)
              return call_native(native, args, filename, line, blk, "#{cls.name}##{name}", kwargs: kwargs)
            end
          end
        elsif recv.rclass?
          # A class receiver uses its singleton methods, not the
          # instance methods meant for its instances.
          cls = recv.as_rclass
          if sym_id = @symbols.lookup(name).try(&.value)
            if method = cls.find_singleton_method(sym_id)
              return call_script_proc(method, args[1..], filename, blk, nil, self_val: recv, block_outer: blk_outer, kwargs: kwargs, block_yield: blk_yield, block_yield_outer: blk_yield_outer)
            end
            if native = cls.find_native_singleton_method(sym_id)
              return call_native(native, args, filename, line, blk, "#{cls.name}.#{name}", kwargs: kwargs)
            end
          end
        elsif interp = @interpreter
          # A builtin value (Integer, String, ...) uses its builtin
          # class.
          if (cls = interp.builtin_class_for(recv)) && (sym_id = @symbols.lookup(name).try(&.value))
            if native = cls.find_native_method(sym_id)
              return call_native(native, args, filename, line, blk, "#{cls.name}##{name}", kwargs: kwargs)
            end
          end
        end
      end

      # 3. An implicit receiver: self's own class first, as in Ruby.
      # Top-level `def`s and `define_native` functions are methods of
      # Object, so this finds them from anywhere.
      unless has_receiver
        if self_val && (sym_id = @symbols.lookup(name).try(&.value))
          if obj = self_val.as_robject?
            # Top-level `include` mixes into Object, as Ruby's `main`
            # does, ahead of any `def include`. Top-level `extend` is
            # not handled and falls through to U018.
            if name == "include" && !args.empty? &&
               (interp = @interpreter) && obj.same?(interp.main) &&
               (mod = args.first.as_rclass?)
              obj.rclass.include_module(mod)
              return self_val
            end

            # self is an object: its class's instance methods.
            cls = obj.rclass
            if method = cls.find_method(sym_id)
              return call_script_proc(method, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs, block_yield: blk_yield, block_yield_outer: blk_yield_outer)
            end
            if native = cls.find_native_method(sym_id)
              return call_native(native, args, filename, line, blk, display_name_for_implicit_self(name), kwargs: kwargs)
            end
          elsif self_rclass = self_val.as_rclass?
            # self is a class or module (in its body). First its own
            # singleton methods (`def self.foo`), then the instance
            # methods of its class (Class or Module) up to Object,
            # which is how `puts` and native functions resolve in a
            # body. Its own instance methods are for its instances,
            # so are not searched.
            if singleton = self_rclass.find_singleton_method(sym_id)
              return call_script_proc(singleton, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs, block_yield: blk_yield, block_yield_outer: blk_yield_outer)
            end
            if native_singleton = self_rclass.find_native_singleton_method(sym_id)
              return call_native(native_singleton, args, filename, line, blk, display_name_for_implicit_self(name), kwargs: kwargs)
            end
            if meta = self_rclass.rclass
              if method = meta.find_method(sym_id)
                return call_script_proc(method, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs, block_yield: blk_yield, block_yield_outer: blk_yield_outer)
              end
              if native = meta.find_native_method(sym_id)
                return call_native(native, args, filename, line, blk, display_name_for_implicit_self(name), kwargs: kwargs)
              end
            end
          end
        end
      end

      # 4. A ScriptProc in the globals. Nothing currently stores one
      # there; kept as a fallback.
      sym = @symbols.lookup(name)
      if sym
        gval = @globals[sym.value]?
        if gval && gval.proc?
          sproc = gval.as_proc.as(ScriptProc)
          return call_script_proc(sproc, args, filename, blk, nil, self_val: self_val, block_outer: blk_outer, kwargs: kwargs, block_yield: blk_yield, block_yield_outer: blk_yield_outer)
        end
      end

      # 5. Builtin operations.
      if result = exec_builtin(name, args, filename, line, blk, kwargs: kwargs)
        return result
      end

      # Nothing resolved. A name Adjutant excludes (`send`, `eval`)
      # gets its U-code, so the reader doesn't retry variations. Checked
      # only now, so a script's own `def send` still works.
      if code = ErrorCatalog::EXCLUDED_METHODS[name]?
        raise excluded_construct(code, name, filename, line)
      end

      # NameError, as Ruby raises for an undefined name.
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

    # Calls a native function or method, turning any Crystal exception
    # into N001. First runs the risk-flow check, which raises
    # RiskFlowRejectedError when policy rejects a labelled argument, or
    # an Ask is answered with Reject.
    private def call_native(native : NativeCallable, args : Array(Value),
                            filename : String, line : Int32, blk : ScriptProc?, name : String,
                            kwargs : Hash(String, Value)? = nil) : Value
      check_unknown_native_keywords!(kwargs, native.kwarg_names, name, filename, line)
      check_risk_flow(native, args, kwargs, name, filename, line)
      NativeFunctionCall.new(self, native, filename, line, name, kwargs).call(args, blk)
    rescue ex : BlockBreakSignal
      # A `break` in the block this call received ends the call with
      # the break's value, as in Ruby.
      ex.value
    rescue ex : FatalSignal
      # A FatalSignal (a denied grant, an exhausted budget) passes
      # through unchanged, past every `rescue`, including
      # `rescue Exception`. This clause only keeps the catch-all below
      # from wrapping it.
      raise ex
    rescue ex : RuntimeError
      raise ex
    rescue ex
      # N, not R: Adjutant can't tell whether the script or the host
      # function is at fault.
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

    # The automatic risk-flow check: each labelled argument against
    # each authority the callable is a sink for. A no-op for callables
    # with no authorities. Keyed on authorities, not the RiskProfile,
    # so describing an effect never changes enforcement.
    private def check_risk_flow(native : NativeCallable, args : Array(Value), kwargs : Hash(String, Value)?,
                                name : String, filename : String, line : Int32) : Nil
      return if native.authorities.empty?
      kwarg_values = kwargs.try(&.values)
      labeled_args = args.any?(&.label)
      labeled_kwargs = kwarg_values.try(&.any?(&.label)) || false
      return unless labeled_args || labeled_kwargs

      matches = [] of RiskFlowMatch
      native.authorities.each do |authority|
        # Keyword values are checked as positional ones are.
        (args + (kwarg_values || [] of Value)).each do |arg|
          label = arg.label
          next unless label
          label.tags.each do |provenance_tag|
            action, rule = @risk_flow_policy.action_for(authority, provenance_tag.sensitivity)
            next if action.allow?
            matches << RiskFlowMatch.new(action, rule, provenance_tag)
          end
        end
      end
      return if matches.empty?

      resolve_risk_flow_matches(matches, name, native.risk, native.authorities, filename, line)
    end

    # The explicit risk-flow check behind
    # `NativeCallContext#declare_sensitivity`: looks up `origin`'s
    # sensitivity (unless given) and runs the policy for `authority`.
    # Returns the label for the data the call returns, whether policy
    # allowed directly or an Ask was answered Allow. `risk` is the
    # native's own profile, shown to whoever answers an Ask.
    def declare_sensitivity(authority : Authority, kind : ProvenanceKind, origin : String, name : String,
                            risk : RiskProfile, filename : String, line : Int32,
                            sensitivity : Sensitivity? = nil) : RiskFlowLabel?
      resolved_sensitivity = sensitivity || @risk_flow_policy.sensitivity_for(kind, origin)
      return if resolved_sensitivity.none?

      label = RiskFlowLabel.of(kind, origin, resolved_sensitivity)

      action, rule = @risk_flow_policy.action_for(authority, resolved_sensitivity)
      return label if action.allow?

      provenance_tag = ProvenanceTag.new(kind, origin, resolved_sensitivity)
      matches = [RiskFlowMatch.new(action, rule, provenance_tag)]
      # Returns only if allowed; otherwise raises.
      resolve_risk_flow_matches(matches, name, risk, Set{authority}, filename, line)
      label
    end

    # Sorts `matches` worst first, builds the decision request, and
    # raises if it is rejected (directly, by `reject_all`, or by the
    # host's answer to an Ask). Returns if allowed.
    private def resolve_risk_flow_matches(matches : Array(RiskFlowMatch), name : String, risk : RiskProfile,
                                          authorities : Set(Authority),
                                          filename : String, line : Int32) : Nil
      # Reject before Ask, then High before Elevated sensitivity.
      matches = matches.sort_by { |match| {-match.action.value, -match.tag.sensitivity.value} }

      request = RiskFlowDecisionRequest.new(name, risk, authorities, matches, filename, line)

      worst_action = matches.first.action
      if worst_action.reject?
        raise_risk_flow_rejected(request, filename, line)
      else
        # An Ask always goes to the host's decision callback.
        decision = @on_risk_flow_decision.call(request)
        raise_risk_flow_rejected(request, filename, line) if decision.reject?
      end
    end

    # Raises RiskFlowRejectedError as a script-catchable error: a
    # RuntimeError carrying an error object of that class.
    private def raise_risk_flow_rejected(request : RiskFlowDecisionRequest, filename : String, line : Int32) : NoReturn
      first = request.matches.first
      reason = first.rule.try { |rule| "#{rule.authority} (#{first.tag})" } || "reject_all policy (#{first.tag})"
      diag = Diagnostic.new(
        code: "F001",
        primary: Span.new(line: line, filename: filename),
        data: {"call" => request.call_name, "reason" => reason}
      )
      # Scripts may `rescue RiskFlowRejectedError`, whatever the host
      # is told.
      cls = builtin_class_by_name("RiskFlowRejectedError")
      err_val = cls ? make_error_object(cls, diag.summary) : Value.string(diag.summary)
      raise RuntimeError.new(diag, filename, line, error_value: err_val)
    end

    # `Foo.new(args)`: a native `new` if the class or an ancestor has
    # one, which allocates and returns its own object; otherwise a new
    # RubyObject and its `initialize`.
    private def construct(cls : RubyClass, args : Array(Value), filename : String, line : Int32, blk : ScriptProc?,
                          kwargs : Hash(String, Value)? = nil) : Value
      raise script_diagnostic("R009", {"module" => cls.name}, current_frame) if cls.is_module?
      if cls.uninstantiable?
        # `Class.new` and `Module.new` are excluded (U002).
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
          # A native `new` accepts the keywords in its `kwarg_names`,
          # like any native call.
          return call_native(native_new, [Value.rclass(cls)] + args, filename, line, blk, "#{cls.name}.new", kwargs: kwargs)
        end
      end
      construct_object(cls, args, filename, line, kwargs)
    end

    # Allocates a RubyObject and runs `initialize`, if the class or an
    # ancestor defines one, returning the object whatever
    # `initialize` returns.
    private def construct_object(cls : RubyClass, args : Array(Value), filename : String, line : Int32,
                                 kwargs : Hash(String, Value)? = nil) : Value
      obj_val = Value.robject(RubyObject.new(cls))
      if sym_id = @symbols.lookup("initialize").try(&.value)
        if init = cls.find_method(sym_id)
          invoke(init, args, self_val: obj_val, kwargs: kwargs)
          return obj_val
        end
      end
      # Without an `initialize`, any keyword is unknown (R012).
      reject_kwargs!(kwargs, "#{cls.name}.new", filename, line)
      obj_val
    end

    # Calls a ScriptProc by pushing its frame, with arguments bound,
    # and returning a placeholder; the `execute` loop runs the frame,
    # and Ret pushes the result to the caller.
    #
    # `self_val` defaults to the caller's self, as a block needs.
    # `lexical_override` replaces the proc's lexical scope, for
    # `invoke`. `blk` is the block passed to `proc`, and `block_outer`
    # the scopes it closes over, for `yield` inside `proc`.
    private def call_script_proc(proc : ScriptProc,
                                 args : Array(Value),
                                 filename : String,
                                 blk : ScriptProc? = nil,
                                 outer : OuterChain? = nil,
                                 self_val : Value? = nil,
                                 lexical_scope : RubyClass? = nil,
                                 lexical_override : Bool = false,
                                 block_outer : OuterChain? = nil,
                                 kwargs : Hash(String, Value)? = nil,
                                 block_yield : ScriptProc? = nil,
                                 own_yield : ScriptProc? = nil,
                                 block_yield_outer : OuterChain? = nil,
                                 own_yield_outer : OuterChain? = nil) : Value
      base = @stack.size
      inherited_self = self_val || (@frames.empty? ? Value.nil_value : current_frame.self_val)
      effective_lexical = if lexical_override
                            lexical_scope
                          else
                            proc.lexical_scope || (@frames.empty? ? nil : current_frame.lexical_scope)
                          end
      # The call site's line, before the callee's frame replaces it.
      caller_line = @frames.empty? ? 0 : current_frame.line
      frame = push_frame(proc, filename, block: blk, stack_base: base, outer: outer, self_val: inherited_self,
        lexical_scope: effective_lexical, block_outer_locals: block_outer, argc: args.size,
        block_yield: block_yield, own_yield: own_yield,
        block_yield_outer: block_yield_outer, own_yield_outer: own_yield_outer)
      frame.kwarg_names = kwargs.keys.to_set if kwargs
      bind_args(frame, proc, args, caller_line, kwargs)
      Value.nil_value # sentinel; Op::Ret will push the real return value
    end

    # Returns the arguments a block binds, spreading a lone Array across
    # the block's parameters when it declares more than one, as Ruby
    # does: `pairs.each { |k, v| }` binds each pair's two elements, and
    # `|a, *rest|` takes the first element and the rest. A block with one
    # parameter, or only a splat, keeps the Array whole. Lambdas never
    # spread; they are called through `invoke_proc`, which does not come
    # here. Elements keep their own labels, as `Array#first` returns them.
    private def spread_block_args(proc : ScriptProc, args : Array(Value),
                                  kwargs : Hash(String, Value)? = nil) : Array(Value)
      return args unless proc.is_block? && args.size == 1 && (kwargs.nil? || kwargs.empty?)
      arr = args[0].as_array?
      params = proc.ast_params
      return args unless arr && params
      positional = params.count { |param| !param.splat? && !param.kwarg? && !param.block_param? }
      spreads = positional > 1 || (positional == 1 && params.any?(&.splat?))
      spreads ? arr.to_a : args
    end

    # Binds a call's arguments into `frame.locals` in declared order:
    #
    #   1. A plain parameter takes the next positional argument, or
    #      stays nil if there is none.
    #   2. A parameter with a default and no argument stays nil; the
    #      compiled prologue then evaluates the default.
    #   3. A splat takes the remaining positional arguments as an
    #      Array.
    #   4. A keyword parameter is bound by name: from `kwargs`, else
    #      left for its default, else R011.
    #
    # Extra positional arguments are ignored, and unknown keywords
    # raise R012. Positional arity is not checked, unlike Ruby. A proc
    # with no `ast_params` binds by position.
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
        # Otherwise left nil: no argument, or a default to come.
      end
      check_unknown_keywords!(kwargs, declared_kwargs, proc, frame, caller_line)
    end

    # Binds one keyword parameter: the supplied value, else nil for
    # the default prologue, else R011.
    private def bind_kwarg_param(frame : Frame, proc : ScriptProc, param : Param, slot : Int32,
                                 kwargs : Hash(String, Value)?, caller_line : Int32) : Nil
      if kwargs && (val = kwargs[param.name]?)
        frame.locals[slot] = val
      elsif param.default.nil?
        # Required and not supplied.
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
      # Otherwise left nil for the default prologue.
    end

    # Raises R012 for the first keyword `proc` doesn't declare, as
    # Ruby does.
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

    # Raises R012 for the first keyword, at a call with no parameter
    # list to bind it to: a class with no `initialize`.
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

    # Raises R012 for the first keyword a native callable doesn't
    # declare in `kwarg_names`; with none declared, any keyword.
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

    # for a splat parameter, labelled and logged as MakeArray labels
    # an array literal, at the call site's `line`.
    private def collect_splat(args : Array(Value), from : Int32, line : Int32) : Value
      elements = from < args.size ? args[from..] : [] of Value
      joined_label = elements.reduce(nil.as(RiskFlowLabel?)) { |acc, value| RiskFlowLabel.join(acc, value.label) }
      @risk_flow_log.record("MakeArray", elements.map(&.label), joined_label, line)
      Value.new(LabeledArray.new(elements, joined_label), joined_label)
    end

    # Operations that resolve when nothing else does: output, `raise`,
    # reflection and the like. Returns nil when `name` isn't one.
    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_builtin(name : String,
                             args : Array(Value),
                             filename : String, line : Int32,
                             blk : ScriptProc? = nil,
                             kwargs : Hash(String, Value)? = nil) : Value?
      reject_kwargs!(kwargs, name, filename, line)
      case name
      when "puts"
        # Each argument's own `to_s`, so `puts :sym` prints `sym`.
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
        # Each argument's own `inspect`.
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
                # `raise NameError, "boo"`: a class and a message.
                cls = args.first.as_rclass
                args[1]?.try(&.to_s) || cls.name
              elsif (obj = args.first.as_robject?) && obj.instance_of?("Exception")
                # `raise NameError.new("boo")`: an error object.
                error_obj = obj # already exception instance
                obj.to_s
              else
                # Anything else: a RuntimeError with it as the message.
                cls = builtin_class_by_name("RuntimeError")
                args.first.to_s
              end
        err_val = if error_obj
                    Value.robject(error_obj)
                  else
                    cls ? make_error_object(cls, msg) : Value.string(msg)
                  end
        raise RuntimeError.new(msg, filename, line, error_value: err_val)
      when "<=>"
        a = args[0]? || Value.nil_value
        b = args[1]? || Value.nil_value
        if a.robject? || b.robject?
          # An object without `<=>` has no default; returning nil
          # here lets dispatch raise R008. One with `<=>` never gets
          # this far.
          nil
        elsif sign = spaceship(a, b, filename, line)
          Value.int(sign.to_i64)
        else
          Value.nil_value
        end
      when "require"
        path = args.first? ? args.first.as_string : ""
        if interp = @interpreter
          interp.require_module(path, filename)
        else
          # A VM without an Interpreter can't `require`: a host
          # wiring fault (H006), not the script's.
          raise HostStateError.new(Diagnostic.new(code: "H006"))
        end
      when "nil?"
        # The receiver is `args[0]`.
        recv = args.first? || Value.nil_value
        Value.bool(recv.null?)
      when "is_a?", "kind_of?"
        # Aliases, as in Ruby.
        recv = args.first? || Value.nil_value
        target = args[1]?.try(&.as_rclass?)
        Value.bool(is_a_target?(recv, target))
      when "class"
        # An object's class, a class's class (usually Class), or a
        # builtin value's class.
        recv = args.first? || Value.nil_value
        cls = recv.as_robject?.try(&.rclass) ||
              recv.as_rclass?.try(&.rclass) ||
              @interpreter.try(&.builtin_class_for(recv))
        cls ? Value.rclass(cls) : Value.nil_value
      when "superclass"
        # A class's superclass; nil for Object. For any other
        # receiver it returns nil, where Ruby raises NoMethodError.
        recv = args.first? || Value.nil_value
        sup = recv.as_rclass?.try(&.superclass)
        sup ? Value.rclass(sup) : Value.nil_value
      when "respond_to?"
        # Whether dispatch would find the method, checking what
        # `dispatch_call` checks. A String name works as well as a
        # Symbol. Operations that exist only here (`to_s`, `class`,
        # `is_a?`, ...) are not seen, so answer false.
        recv = args.first? || Value.nil_value
        method_arg = args[1]? || Value.nil_value
        method_name = method_arg.as_sym?.try(&.name) || method_arg.as_string?
        Value.bool(method_name ? script_responds_to?(recv, method_name) : false)
      when "equal?"
        # Identity. Values with equal content are identical here, as
        # Ruby's immediates are; two equal Strings are too, unlike
        # Ruby.
        recv = args.first? || Value.nil_value
        other = args[1]? || Value.nil_value
        Value.bool(recv == other)
      when "dup", "clone"
        # An object's shallow copy: a new object of the same class
        # with the ivars copied, then its `initialize_copy(original)`
        # if defined. `initialize` doesn't run. There is no frozen
        # state, so `dup` and `clone` are the same. Other receivers get
        # nil here, which dispatch reports as NoMethodError.
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
        end
      when "to_s"
        recv = args.first? || Value.nil_value
        Value.string(recv.to_s)
      when "inspect"
        # A class's default `inspect`, its qualified name, as `to_s`
        # gives. Other receivers resolve `inspect` before reaching
        # here.
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
      end
    end

    # --- Operators ------------------------------------------------------------
    # The arithmetic and comparison logic is in ValueOps. These
    # wrappers serve NativeCallContext, which calls them by name.

    # `filename` and `line` default to the current frame; a native
    # caller passes its call site, so R013 points there.
    protected def compare(a : Value, b : Value, op : Symbol,
                          filename : String = current_frame.filename,
                          line : Int32 = current_frame.line) : Bool
      # An object operand dispatches to its `<=>`, standing in for
      # Comparable. Base types are ordered by ValueOps.
      if a.robject? || b.robject?
        compare_via_spaceship(a, b, op, filename, line)
      else
        ValueOps.compare(a, b, op)
      end
    end

    # Ruby's `+` for native code, raising as Add does. An object's
    # own `+` is not dispatched.
    protected def add(a : Value, b : Value) : Value
      ValueOps.add(a, b, error_raiser(current_frame))
    end

    # `<`/`<=`/`>`/`>=` in script code. Unlike `compare`, which answers
    # `false` for a pair it cannot order (Range bounds and `===` rely on
    # that), this raises R044 (`ArgumentError`) for two base-type values
    # with no order between them, such as `1 < "a"` or two Arrays —
    # matching Ruby, and turning a silent `false` into a visible error.
    private def strict_compare(a : Value, b : Value, op : Symbol) : Bool
      unless a.robject? || b.robject? || ValueOps.orderable?(a, b)
        raise_incomparable(a, b, current_frame.filename, current_frame.line)
      end
      compare(a, b, op)
    end

    # Orders `a` against `b` as Ruby's `<=>` does: a negative, zero or
    # positive Int32, or nil when the pair has no order. Arrays compare
    # element by element, then by length. A RubyObject receiver uses its
    # own `<=>`, which must return an Integer or nil (R013 otherwise).
    protected def spaceship(a : Value, b : Value,
                            filename : String = current_frame.filename,
                            line : Int32 = current_frame.line) : Int32?
      if a.array? && b.array?
        xs = a.as_array
        ys = b.as_array
        Math.min(xs.size, ys.size).times do |i|
          sign = spaceship(xs[i], ys[i], filename, line)
          return unless sign
          return sign unless sign == 0
        end
        return xs.size <=> ys.size
      end

      if a.robject?
        sign_val = call_method(a, "<=>", [b], filename, line)
        return if sign_val.null?
        raise_bad_spaceship(a, b, sign_val, filename, line) unless sign_val.int?
        return sign_val.as_int <=> 0
      end

      ValueOps.spaceship(a, b)
    end

    # `spaceship`, raising R044 (`ArgumentError`) when the pair has no
    # order. For native methods that must order every pair they meet,
    # such as `Array#sort`.
    protected def order(a : Value, b : Value, filename : String, line : Int32) : Int32
      spaceship(a, b, filename, line) || raise_incomparable(a, b, filename, line)
    end

    private def raise_incomparable(a : Value, b : Value, filename : String, line : Int32) : NoReturn
      raise runtime_diagnostic(
        Diagnostic.new(
          code: "R044",
          primary: Span.new(line: line, filename: filename),
          data: {"left" => describe_value(a), "right" => describe_value(b)}
        ),
        current_frame,
        error_class: "ArgumentError"
      )
    end

    private def raise_bad_spaceship(a : Value, b : Value, sign_val : Value,
                                    filename : String, line : Int32) : NoReturn
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

    # `a < b` as `a.<=>(b)` compared with zero. An object without
    # `<=>` raises as for any undefined method.
    private def compare_via_spaceship(a : Value, b : Value, op : Symbol,
                                      filename : String, line : Int32) : Bool
      sign_val = call_method(a, "<=>", [b], filename, line)
      unless sign_val.int?
        # A `<=>` result that isn't an Integer raises ArgumentError,
        # as Comparable does in Ruby.
        raise_bad_spaceship(a, b, sign_val, filename, line)
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
        # An object with `<=>` gets `==` derived from it, as
        # Comparable gives in Ruby: equal when `<=>` returns 0, and
        # not equal when it returns anything else or raises. Without
        # `<=>`, `==` is identity.
        robject_equal_via_spaceship?(a, b)
      else
        ValueOps.equal?(a, b)
      end
    end

    # Whether `a.<=>(b)` returns 0. A RuntimeError from `<=>` counts
    # as not equal, as in Comparable#==; the one place a script's
    # error is swallowed.
    private def robject_equal_via_spaceship?(a : Value, b : Value) : Bool
      sign_val = call_method(a, "<=>", [b])
      sign_val.int? && sign_val.as_int == 0
    rescue RuntimeError
      false
    end

    # Add and Sub: an object on the left with its own `+` or `-` gets
    # it called; anything else uses ValueOps, so `1 + 2` never
    # dispatches.
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

    # `/`, dispatched as in `exec_add`; `Legate::Path#/` uses it.
    private def exec_div(lhs : Value, rhs : Value, f : Frame) : Value
      if lhs.robject? && script_responds_to?(lhs, "/")
        call_method(lhs, "/", [rhs], f.filename, f.line)
      else
        ValueOps.div(lhs, rhs, error_raiser(f))
      end
    end

    # Range `==`: equal bounds and exclusivity, as in Ruby. Here
    # rather than in ValueOps, which has no access to the Range class
    # or the ivar symbols.
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

    # Indexing anything but an Array, Hash or String: an object's
    # native `[]` is called. Anything else, including an object
    # without a native `[]`, gives nil. A script-defined `[]` would
    # push a frame this synchronous path can't wait for; U017 makes
    # one impossible to write.
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

    # The `on_error` callback for ValueOps: raises the named error
    # class ("TypeError", "ZeroDivisionError") through
    # `runtime_error`.
    private def error_raiser(frame : Frame) : ValueOps::OnError
      ->(msg : String, error_class : String) { raise runtime_error(msg, frame, error_class: error_class) }
    end

    private def runtime_error(msg : String, frame : Frame = current_frame, cause = nil, error_class : String = "RuntimeError") : RuntimeError
      cls = builtin_class_by_name(error_class)
      err_val = cls ? make_error_object(cls, msg) : nil
      RuntimeError.new(msg, frame, cause, error_value: err_val)
    end

    # `runtime_error` carrying a Diagnostic for the host. The script's
    # error object gets only the summary as its message. Spans have a
    # line and no column, since Frame records none. `error_class` is
    # what a script rescues and must match Ruby's choice, whatever the
    # code.
    private def runtime_diagnostic(diag : Diagnostic, frame : Frame = current_frame,
                                   cause = nil, error_class : String = "RuntimeError") : RuntimeError
      cls = builtin_class_by_name(error_class)
      err_val = cls ? make_error_object(cls, diag.summary) : nil
      RuntimeError.new(diag, frame, cause, error_value: err_val)
    end

    # Raises a catalog diagnostic for a native method, at the call
    # site `filename` and `line`. See `NativeCallContext#raise_error`.
    protected def raise_native_error(code : String, data : Hash(String, String),
                                     error_class : String, filename : String, line : Int32) : NoReturn
      raise runtime_diagnostic(
        Diagnostic.new(code: code, primary: Span.new(line: line, filename: filename), data: data),
        current_frame,
        error_class: error_class
      )
    end

    # Raises `error_class` with a computed message and optional
    # attributes, as `raise ClassName, "msg"` does. No Diagnostic: the
    # message is built per call. See
    # `NativeCallContext#raise_error_class`.
    protected def raise_native_error_class(message : String, error_class : RubyClass,
                                           filename : String, line : Int32,
                                           attributes : Hash(String, Value)? = nil) : NoReturn
      err_val = make_error_object(error_class, message, attributes)
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

    # A value's type as a script author would name it, rather than
    # its Crystal type.
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

    # The error for reassigning a constant. If both values are classes
    # or modules, this is a reopened class (U003); otherwise an
    # ordinary reassigned constant (R001).
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

    # A NameError, as Ruby raises for an unresolved name.
    private def name_error(msg : String, filename : String, line : Int32, cause = nil) : RuntimeError
      cls = builtin_class_by_name("NameError")
      err_val = cls ? make_error_object(cls, msg) : nil
      RuntimeError.new(msg, filename, line, cause, error_value: err_val)
    end

    # A class registered by the interpreter, by name: error classes,
    # Range and the like. Nil if missing.
    private def builtin_class_by_name(name : String) : RubyClass?
      sym = @symbols.lookup(name)
      return unless sym
      @globals[sym.value]?.try(&.as_rclass?)
    end

    # A Range object, with its bounds and exclusivity in the `__min`,
    # `__max` and `__exclusive` ivars, which `builtins/range.cr` reads
    # by the same names.
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

    # A Regexp object for MakeRegex. An invalid pattern raises R021
    # (RegexpError), as `Regexp.new` does.
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
      # `source` carries the pattern's label, as for `Regexp.new`.
      obj.ivars[@symbols.intern("__source").value] = Value.string(pattern, label)
      obj.ivars[@symbols.intern("__options").value] = Value.int(flags)
      Value.robject(obj, label)
    end

    # A Proc object wrapping a lambda's ScriptProc. Block literals
    # and def bodies stay bare ScriptProcs.
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
      # Where the lambda was written, for `to_s`, as Ruby reports.
      obj.ivars[@symbols.intern("__filename").value] = Value.string(filename)
      obj.ivars[@symbols.intern("__line").value] = Value.int(line.to_i64)
      # This evaluation's closure; each evaluation of the literal gets
      # its own.
      obj.outer_locals = outer_locals
      Value.robject(obj, label)
    end

    # An error object of `cls` with its `message`, so a rescue can call
    # `.message` on any error.
    private def make_error_object(cls : RubyClass, message : String,
                                  attributes : Hash(String, Value)? = nil) : Value
      obj = RubyObject.new(cls)
      msg_sym = @symbols.intern("message")
      obj.ivars[msg_sym.value] = Value.string(message)
      # Applied after `message`, so a "message" attribute overrides
      # it.
      attributes.try &.each do |name, value|
        obj.ivars[@symbols.intern(name).value] = value
      end
      Value.robject(obj)
    end

    # The message of an error value: an object's `message` ivar, a
    # string itself, or anything else's `to_s`.
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

    # Clears the rescue target of the frame's top handler entry, and
    # pops the entry if it has no ensure, since EnterEnsure never will.
    private def clear_rescue_portion(frame : Frame) : Nil
      if top = frame.handlers.last?
        top.rescue_ip = nil
        frame.handlers.pop? if top.ensure_ip.nil?
      end
    end
  end
end
