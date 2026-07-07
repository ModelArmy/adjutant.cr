require "./ast"
require "./bytecode"
require "./risk_node"
require "./type_hint"
require "./type_inference"
require "./interpreter"

module Adjutant
  # Walks an AST body (top-level script, or a ScriptProc's stored
  # ast_body) into a RiskNode tree, resolving each Call node to a
  # NativeCallable/ScriptProc risk profile via TypeInference.
  #
  # Scope and honesty notes, deliberately conservative:
  #
  #   - A Call's receiver type comes from TypeInference, run linearly
  #     alongside this walk (see walk_body — the two walks share one
  #     Env, since risk and type both depend on the same var bindings
  #     in the same control-flow order).
  #   - A ScriptProc's own body is walked using ONLY its own param
  #     scope (all params UnknownType) — NOT the caller's env. Method
  #     risk is memoized per ScriptProc, independent of call site, so
  #     it must not depend on caller-supplied argument types. This is
  #     a real precision loss: `def process(f); f.read; end` always
  #     sees `f` as UnknownType inside `process`, regardless of what
  #     any call site passes, because Adjutant has no parameter type
  #     declarations (see DEVELOPMENT.md's "Structured risk" section
  #     for the caveat and why fixing it means adding real type
  #     annotations to the language, not a bigger inference pass).
  #   - Recursion: a ScriptProc currently being walked (@in_progress)
  #     that calls itself (directly or via mutual recursion) becomes a
  #     RiskLeaf tagged "recursive call" instead of a fresh descent —
  #     prevents infinite walker recursion. Loops get the same
  #     "unknown repeat count" treatment via RiskSequence#iterated;
  #     recursion is escalated the same way, since neither the walker
  #     nor the runtime can statically bound how many times either
  #     will actually execute.
  #   - Memoization is keyed on ScriptProc identity (object, not name)
  #     — correct since risk assessment is a compile-time property
  #     here, not a runtime one, and a proc's body risk never changes
  #     between calls.
  class RiskWalker
    # Top-level defs seen SO FAR in the walk — mirrors the VM's own
    # linear execution: a call before its def is genuinely unresolved
    # here, same as the NameError it would raise at runtime. Populated
    # as walk_body encounters DefNode statements, not by a separate
    # pre-pass.
    @top_level_procs : Hash(String, ScriptProc)

    # Classes built SO FAR — same order-sensitivity for the class
    # declaration itself (a class must be declared before use), but
    # NOT for calls between its own methods (see walk_class): a method
    # body is only ever invoked after the class body has fully
    # finished executing, so by then every method in it is registered
    # regardless of definition order within the class.
    @known_classes : Hash(String, RubyClass)

    def initialize(@interp : Interpreter)
      @inference = TypeInference.new(@interp)
      @method_cache = {} of ScriptProc => RiskNode
      @in_progress = Set(ScriptProc).new
      @top_level_procs = {} of String => ScriptProc
      @known_classes = {} of String => RubyClass
      @inference.class_resolver = ->(name : String) { resolve_class(name) }
    end

    # Classes the walker has built for itself take priority — they
    # don't exist in @interp's globals at all, since the script hasn't
    # run. Falls back to @interp for genuinely pre-existing classes
    # (builtins, classes defined by a prior interp.eval in the host
    # program) — see class docs above @known_classes.
    private def resolve_class(name : String) : RubyClass?
      @known_classes[name]? || @interp.get_global(name).as_rclass?
    end

    # Entry point for a top-level script body.
    def walk_body(body : Body, env : TypeInference::Env = TypeInference::Env.new) : RiskNode
      children = body.stmts.map { |stmt| walk_node(stmt, env).as(RiskNode) }
      RiskSequence.new(children, body.line)
    end

    def walk_node(node : Node, env : TypeInference::Env) : RiskNode
      case node
      when IfNode, UnlessNode, CaseNode, WhileNode, LoopNode, ForNode, ModifierIf, ModifierWhile, BeginNode
        walk_control_flow(node, env)
      when Assign, OpAssign, CondAssign, MultiAssign, IndexAssign
        walk_assignment(node, env)
      when Call       then walk_call(node, env)
      when Body       then walk_body(node, env)
      when DefNode    then walk_def(node)
      when ClassNode  then walk_class(node)
      when ModuleNode then walk_module(node)
      else
        # Any other node kind (literals, etc.) carries no risk of its
        # own, but may still affect var types (rare outside Assign) —
        # run inference for env-tracking consistency.
        @inference.infer_node(node, env)
        RiskSequence.new([] of RiskNode, node.line)
      end
    end

    private def walk_control_flow(node : Node, env : TypeInference::Env) : RiskNode
      case node
      when IfNode        then walk_if(node, env)
      when UnlessNode    then walk_unless(node, env)
      when CaseNode      then walk_case(node, env)
      when WhileNode     then walk_iterated(node.body, env, node.line)
      when LoopNode      then walk_iterated(node.body, env, node.line)
      when ForNode       then walk_iterated(node.body, env, node.line)
      when ModifierIf    then walk_modifier_if(node, env)
      when ModifierWhile then walk_modifier_while(node, env)
      when BeginNode     then walk_begin(node, env)
      else                    RiskSequence.new([] of RiskNode, node.line)
      end
    end

    private def walk_assignment(node : Node, env : TypeInference::Env) : RiskNode
      case node
      when Assign      then walk_assign(node, env)
      when OpAssign    then walk_op_assign(node, env)
      when CondAssign  then walk_cond_assign(node, env)
      when MultiAssign then walk_multi_assign(node, env)
      when IndexAssign then walk_index_assign(node, env)
      else                  RiskSequence.new([] of RiskNode, node.line)
      end
    end

    # `unless cond; ...; else; ...; end` — same Choice shape as IfNode.
    # Note: unlike walk_if, this does NOT call into TypeInference for
    # env-merging (no infer_unless exists) — a var assigned only
    # inside an unless-branch won't propagate as Known to later
    # siblings. Safe direction to err (falls back to UnknownType, not
    # a wrong guess), but a real gap if UnlessNode type-tracking
    # becomes needed later.
    private def walk_unless(node : UnlessNode, env : TypeInference::Env) : RiskNode
      branches = [] of RiskNode
      branches << walk_body(node.then_branch, env.dup)
      if else_branch = node.else_branch
        branches << walk_body(else_branch, env.dup)
      else
        branches << RiskSequence.new([] of RiskNode, node.line)
      end
      RiskChoice.new(branches, "unless", node.line)
    end

    # `expr if cond` / `expr unless cond` — a Choice between running
    # expr once and not running it at all (the implicit "else" is a
    # no-op, same treatment as IfNode's missing else_branch).
    private def walk_modifier_if(node : ModifierIf, env : TypeInference::Env) : RiskNode
      body_env = env.dup
      body_risk = walk_node(node.body, body_env)
      RiskChoice.new([body_risk, RiskSequence.new([] of RiskNode, node.line)] of RiskNode,
        node.negated? ? "unless" : "if", node.line)
    end

    # `expr while cond` / `expr until cond` — same "unknown repeat
    # count" treatment as WhileNode, just a single-statement body.
    private def walk_modifier_while(node : ModifierWhile, env : TypeInference::Env) : RiskNode
      inner_env = env.dup
      body_risk = walk_node(node.body, inner_env)
      RiskSequence.new([body_risk] of RiskNode, node.line, iterated: true)
    end

    # begin/rescue/ensure: body and rescue_body are mutually exclusive
    # (Choice — exactly one runs), ensure_body always runs afterward
    # regardless of which (Sequence wrapping the Choice). No rescue
    # clause at all degrades to a plain Sequence(body, ensure) — there's
    # nothing to choose between.
    private def walk_begin(node : BeginNode, env : TypeInference::Env) : RiskNode
      body_env = env.dup
      body_risk = walk_body(node.body, body_env)

      try_result =
        if rescue_body = node.rescue_body
          rescue_env = env.dup
          rescue_risk = walk_body(rescue_body, rescue_env)
          RiskChoice.new([body_risk, rescue_risk] of RiskNode, "rescue", node.line)
        else
          body_risk
        end

      if ensure_body = node.ensure_body
        ensure_env = env.dup
        ensure_risk = walk_body(ensure_body, ensure_env)
        RiskSequence.new([try_result, ensure_risk] of RiskNode, node.line)
      else
        try_result
      end
    end

    # A `module` statement — same treatment as ClassNode minus
    # superclass/instantiation; modules can't be `.new`'d, but their
    # methods can still be called (once `include`/module-function
    # dispatch exists) and their bodies can contain bare statements
    # that execute immediately, same as a class body.
    private def walk_module(node : ModuleNode) : RiskNode
      mod = RubyClass.new(node.name, nil, is_module: true)
      @known_classes[node.name] = mod

      children = node.body.stmts.map do |stmt|
        if stmt.is_a?(DefNode) && stmt.receiver.nil?
          register_class_method(mod, stmt)
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        else
          walk_node(stmt, TypeInference::Env.new).as(RiskNode)
        end
      end
      RiskSequence.new(children, node.line)
    end

    # A `def` statement itself has no risk — it registers a name,
    # doesn't run the body. The body is walked lazily, on first call
    # (see walk_script_method), same as today's memoization.
    # Placeholder ScriptProc: chunk is never read by the walker (only
    # ast_body/ast_params/params/name are), so an empty Chunk is a
    # safe stand-in — this proc is never executed, only walked.
    private def walk_def(node : DefNode) : RiskNode
      proc = ScriptProc.new(Chunk.new, node.name, node.params.map(&.name),
        ast_body: node.body, ast_params: node.params)
      @top_level_procs[node.name] = proc
      RiskSequence.new([] of RiskNode, node.line)
    end

    # A `class` statement walks its body immediately (bare statements
    # in a class body execute right away, same as top-level — see
    # DEVELOPMENT.md's RiskWalker section), registering each nested
    # DefNode as a method on the RubyClass being built. Any bare call
    # in the class body resolves against the ENCLOSING scope's table
    # (@top_level_procs, @known_classes as they stand at this point in
    # the walk) — a class body isn't its own top-level scope.
    private def walk_class(node : ClassNode) : RiskNode
      superclass = node.superclass.try { |name| resolve_class(name) }
      cls = RubyClass.new(node.name, superclass)
      @known_classes[node.name] = cls

      children = node.body.stmts.map do |stmt|
        if stmt.is_a?(DefNode) && stmt.receiver.nil?
          register_class_method(cls, stmt)
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        else
          walk_node(stmt, TypeInference::Env.new).as(RiskNode)
        end
      end
      RiskSequence.new(children, node.line)
    end

    private def register_class_method(cls : RubyClass, node : DefNode) : Nil
      proc = ScriptProc.new(Chunk.new, node.name, node.params.map(&.name),
        ast_body: node.body, ast_params: node.params)
      sym_id = @interp.symbols.intern(node.name).value
      cls.define_method(sym_id, proc)
    end

    # The risk of an assignment's VALUE expression (e.g. a risky call
    # used as an initializer, `f = File.new(path)`) must be walked for
    # risk, not just inferred for type — walk_node's generic else
    # branch only ran type inference and would silently drop this.
    private def walk_assign(node : Assign, env : TypeInference::Env) : RiskNode
      value_risk = walk_node(node.value, env)
      # Mirror TypeInference#infer_assign's env update so subsequent
      # siblings see the binding — infer_node on the value again here
      # would be redundant work but is idempotent (no side effects
      # beyond env, and env already reflects the walk above via
      # walk_call/walk_node's own infer_node calls); simplest correct
      # approach is to update env directly from the value's type here.
      value_type = @inference.infer_node(node.value, env)
      if (target = node.target).is_a?(Identifier)
        env[target.name] = value_type
      end
      value_risk
    end

    # `x += expr` — same rationale as walk_assign: expr's risk must be
    # walked, not just inferred for type. The target's post-op type
    # isn't tracked precisely (e.g. `x += 1` doesn't know x stays
    # Integer) — TypeInference has no infer_op_assign, so the target
    # degrades to whatever infer_node says about a bare read of
    # node.value, which is imprecise but errs toward UnknownType, not
    # a wrong guess.
    private def walk_op_assign(node : OpAssign, env : TypeInference::Env) : RiskNode
      value_risk = walk_node(node.value, env)
      if (target = node.target).is_a?(Identifier)
        env.delete(target.name)
      end
      value_risk
    end

    # `x ||= expr` / `x &&= expr` — same shape as OpAssign.
    private def walk_cond_assign(node : CondAssign, env : TypeInference::Env) : RiskNode
      value_risk = walk_node(node.value, env)
      if (target = node.target).is_a?(Identifier)
        env.delete(target.name)
      end
      value_risk
    end

    # `a, b = 1, 2` — each value expression walked for risk in order
    # (Sequence: all run); targets aren't type-tracked here (no
    # infer_multi_assign in TypeInference) so they degrade to
    # UnknownType on next read, same safe-imprecise direction as
    # OpAssign/CondAssign above.
    private def walk_multi_assign(node : MultiAssign, env : TypeInference::Env) : RiskNode
      children = node.values.map { |value| walk_node(value, env).as(RiskNode) }
      node.targets.each do |target|
        env.delete(target.name) if target.is_a?(Identifier)
      end
      RiskSequence.new(children, node.line)
    end

    # `arr[i] = expr` — target/index/value can each carry risk (e.g.
    # `arr[compute_index()] = fetch_value()`); all three walked as a
    # Sequence since all evaluate unconditionally.
    private def walk_index_assign(node : IndexAssign, env : TypeInference::Env) : RiskNode
      children = [
        walk_node(node.target, env).as(RiskNode),
        walk_node(node.index, env).as(RiskNode),
        walk_node(node.value, env).as(RiskNode),
      ]
      RiskSequence.new(children, node.line)
    end

    private def walk_if(node : IfNode, env : TypeInference::Env) : RiskNode
      branches = [] of RiskNode
      then_env = env.dup
      branches << walk_body(node.then_branch, then_env)

      node.elsif_branches.each do |(_cond, body)|
        b_env = env.dup
        branches << walk_body(body, b_env)
      end

      if else_branch = node.else_branch
        else_env = env.dup
        branches << walk_body(else_branch, else_env)
      else
        branches << RiskSequence.new([] of RiskNode, node.line)
      end

      # Keep TypeInference's own env merge semantics for subsequent
      # sibling statements — same merge the standalone inference pass
      # uses, just invoked here so the risk walk and type env stay in
      # lockstep as one traversal.
      @inference.infer_if(node, env)
      RiskChoice.new(branches, "if", node.line)
    end

    private def walk_case(node : CaseNode, env : TypeInference::Env) : RiskNode
      branches = [] of RiskNode
      node.whens.each do |(_conds, body)|
        b_env = env.dup
        branches << walk_body(body, b_env)
      end
      if else_branch = node.else_branch
        else_env = env.dup
        branches << walk_body(else_branch, else_env)
      else
        branches << RiskSequence.new([] of RiskNode, node.line)
      end
      @inference.infer_case(node, env)
      RiskChoice.new(branches, "case", node.line)
    end

    private def walk_iterated(body : Body, env : TypeInference::Env, line : Int32) : RiskNode
      inner_env = env.dup
      node = walk_body(body, inner_env)
      RiskSequence.new([node.as(RiskNode)], line, iterated: true)
    end

    private def walk_call(node : Call, env : TypeInference::Env) : RiskNode
      receiver = node.receiver
      if receiver.nil?
        walk_receiverless_call(node)
      elsif receiver.is_a?(Constant) && node.method == "new"
        walk_constructor_call(node, receiver)
      else
        receiver_type = @inference.infer_node(receiver, env)
        walk_receiver_call(node, receiver_type)
      end
    end

    # `ClassName.new(...)` — mirrors TypeInference#infer_call's special
    # case. `.new` itself isn't a registered native/script method
    # today (no singleton-method support yet — see DEVELOPMENT.md), so
    # it carries no RiskProfile of its own; treating it as an ordinary
    # unresolved Call would wrongly flag every object construction.
    # Once native `.new` (e.g. a future File.new) gets a real
    # RiskProfile via singleton-method dispatch, this should resolve
    # to THAT profile instead of assuming zero risk unconditionally.
    private def walk_constructor_call(node : Call, receiver : Constant) : RiskNode
      cls = resolve_class(receiver.name)
      if cls
        RiskSequence.new([] of RiskNode, node.line)
      else
        RiskUnresolved.new("#{receiver.name}.new", node.line)
      end
    end

    # `some_fn(args)` — resolves in the same order the VM would at
    # this point in execution: native functions and any ALREADY
    # EXECUTED top-level def (from a prior interp.eval — genuinely
    # pre-existing, same footing as a native function), then a
    # top-level def SEEN SO FAR in this walk itself. A call before its
    # def within the walked script is genuinely unresolved, matching
    # the NameError Adjutant would raise at runtime — see class docs
    # for why this diverges from the "define once, call safely from
    # anywhere in the class" rule that DOES apply inside method bodies
    # (walk_class).
    private def walk_receiverless_call(node : Call) : RiskNode
      sym = @interp.symbols.lookup(node.method)
      if sym
        if native = @interp.native_callable(sym.value)
          return RiskLeaf.new(native.risk, node.method, node.line)
        end
        gval = @interp.get_global(node.method)
        if gval.proc?
          return walk_script_method(gval.as_proc.as(ScriptProc), node.line)
        end
      end
      if proc = @top_level_procs[node.method]?
        return walk_script_method(proc, node.line)
      end
      RiskUnresolved.new(node.method, node.line)
    end

    private def walk_receiver_call(node : Call, receiver_type : TypeHint) : RiskNode
      case receiver_type
      when KnownType
        walk_known_receiver_call(node, receiver_type)
      else
        RiskUnresolved.new("#{node.method} (receiver type unknown)", node.line)
      end
    end

    # A KnownType may hold more than one class (union from a branch
    # merge) — resolve the call against EACH possible class and treat
    # the result as a Choice, since which class the receiver actually
    # is at runtime is itself a runtime fact the walker can't narrow
    # further. A receiver that's unambiguously one class (the common
    # case) becomes a Choice of one child — harmless.
    private def walk_known_receiver_call(node : Call, receiver_type : KnownType) : RiskNode
      branches = receiver_type.classes.map { |cls| resolve_on_class(cls, node).as(RiskNode) }
      if branches.size == 1
        branches.first
      else
        RiskChoice.new(branches, "possible receiver type", node.line)
      end
    end

    private def resolve_on_class(cls : RubyClass, node : Call) : RiskNode
      sym = @interp.symbols.lookup(node.method)
      return RiskUnresolved.new("#{cls.name}##{node.method}", node.line) unless sym

      if script_method = cls.find_method(sym.value)
        walk_script_method(script_method, node.line)
      elsif native = cls.find_native_method(sym.value)
        RiskLeaf.new(native.risk, "#{cls.name}##{node.method}", node.line)
      else
        RiskUnresolved.new("#{cls.name}##{node.method}", node.line)
      end
    end

    # Walks a ScriptProc's body using only its own param scope — see
    # class-level docs for why caller argument types can't flow in.
    # Memoized per ScriptProc; guarded against recursion.
    private def walk_script_method(proc : ScriptProc, call_line : Int32) : RiskNode
      if cached = @method_cache[proc]?
        return cached
      end
      if @in_progress.includes?(proc)
        return RiskLeaf.new(RiskProfile.none, "#{proc.name} (recursive call)", call_line)
      end

      ast_body = proc.ast_body
      unless ast_body
        # No AST retained (e.g. a ScriptProc built directly from a
        # Chunk in a test, bypassing the compiler's normal path) —
        # can't be walked; honestly unresolved rather than assumed safe.
        return RiskUnresolved.new("#{proc.name} (no AST available)", call_line)
      end

      @in_progress << proc
      method_env = TypeInference::Env.new
      proc.params.each { |param| method_env[param] = UnknownType.new }
      result = walk_body(ast_body, method_env)
      @in_progress.delete(proc)
      @method_cache[proc] = result
      result
    end
  end
end
