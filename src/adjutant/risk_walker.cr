require "./ast"
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
    def initialize(@interp : Interpreter)
      @inference = TypeInference.new(@interp)
      @method_cache = {} of ScriptProc => RiskNode
      @in_progress = Set(ScriptProc).new
    end

    # Entry point for a top-level script body.
    def walk_body(body : Body, env : TypeInference::Env = TypeInference::Env.new) : RiskNode
      children = body.stmts.map { |stmt| walk_node(stmt, env).as(RiskNode) }
      RiskSequence.new(children, body.line)
    end

    def walk_node(node : Node, env : TypeInference::Env) : RiskNode
      case node
      when IfNode    then walk_if(node, env)
      when CaseNode  then walk_case(node, env)
      when WhileNode then walk_iterated(node.body, env, node.line)
      when LoopNode  then walk_iterated(node.body, env, node.line)
      when ForNode   then walk_iterated(node.body, env, node.line)
      when Call      then walk_call(node, env)
      when Assign    then walk_assign(node, env)
      when Body      then walk_body(node, env)
      else
        # Any other node kind (literals, etc.) carries no risk of its
        # own, but may still affect var types (rare outside Assign) —
        # run inference for env-tracking consistency.
        @inference.infer_node(node, env)
        RiskSequence.new([] of RiskNode, node.line)
      end
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
      cls = @interp.get_global(receiver.name).as_rclass?
      if cls
        RiskSequence.new([] of RiskNode, node.line)
      else
        RiskUnresolved.new("#{receiver.name}.new", node.line)
      end
    end

    # `some_fn(args)` — resolves via Interpreter#native_callable first,
    # then a top-level ScriptProc stored in globals — same order as
    # VM#dispatch_call's steps 2 and 3, so resolution here matches
    # what would actually run.
    private def walk_receiverless_call(node : Call) : RiskNode
      sym = @interp.symbols.lookup(node.method)
      return RiskUnresolved.new(node.method, node.line) unless sym

      if native = @interp.native_callable(sym.value)
        return RiskLeaf.new(native.risk, node.method, node.line)
      end
      gval = @interp.get_global(node.method)
      if gval.proc?
        return walk_script_method(gval.as_proc.as(ScriptProc), node.line)
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
