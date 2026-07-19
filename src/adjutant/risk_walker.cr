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

    # Constant-name -> the Lambda AST node it was assigned. Same
    # "seen so far, in walk order" precedent as @top_level_procs/
    # @known_classes above, and only trustworthy for the same reason
    # those two are (a name, once bound, doesn't change again) — here
    # specifically because Op::SetConstant now enforces that at
    # runtime too (Piece D, SCOPE.md). Populated by walk_assign as
    # `CONST = ->(){}` statements are walked.
    @known_constant_lambdas : Hash(String, Lambda)

    def initialize(@interp : Interpreter)
      @inference = TypeInference.new(@interp)
      @method_cache = {} of ScriptProc => RiskNode
      @in_progress = Set(ScriptProc).new
      # Same purpose as @method_cache/@in_progress, keyed by the Lambda
      # AST node itself rather than a ScriptProc — walk_lambda_body
      # works from the AST directly (a Lambda literal isn't compiled/
      # instantiated at walk time the way a def's ScriptProc is).
      # @in_progress_lambdas matters for real: a bare Lambda literal
      # can't reference itself (no name exists yet inside its own
      # body — real Ruby semantics), but a CONSTANT-held lambda's body
      # calling `.call` on that same constant IS structurally possible
      # (`F1 = ->() { F1.call }` — F1 exists by the time the body would
      # run) and needs the same recursion guard walk_script_method
      # already has for defs.
      @lambda_cache = {} of Lambda => RiskNode
      @in_progress_lambdas = Set(Lambda).new
      @top_level_procs = {} of String => ScriptProc
      @known_classes = {} of String => RubyClass
      @known_constant_lambdas = {} of String => Lambda
      @inference.class_resolver = ->(name : String) { resolve_class(name) }
      @inference.const_path_resolver = ->(node : ConstPath) { resolve_const_path(node) }
    end

    # Classes the walker has built for itself take priority — they
    # don't exist in @interp's globals at all, since the script hasn't
    # run. Falls back to @interp for genuinely pre-existing classes
    # (builtins, classes defined by a prior interp.eval in the host
    # program) — see class docs above @known_classes.
    private def resolve_class(name : String) : RubyClass?
      @known_classes[name]? || @interp.get_global(name).as_rclass?
    end

    # Resolves a ConstPath (`M::A`, or deeper: `M::N::A`) to a
    # RubyClass by walking its namespace chain — mirrors the VM's
    # Op::GetConstantFrom (a direct, non-lexical lookup in each
    # resolved namespace's own `constants` table, populated by
    # walk_nested as class/module statements are walked). The
    # innermost namespace is itself resolved via resolve_class if it's
    # a bare Constant, or recursively if it's another ConstPath.
    private def resolve_const_path(node : ConstPath) : RubyClass?
      ns = node.namespace
      owner = case ns
              when Constant  then resolve_class(ns.name)
              when ConstPath then resolve_const_path(ns)
              else                nil
              end
      return nil unless owner
      sym = @interp.symbols.lookup(node.name)
      return nil unless sym
      owner.constants[sym.value]?.try(&.as_rclass?)
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
      when Identifier then walk_identifier(node, env)
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
      when ForNode       then walk_iterated(node.body, env, node.line, node.vars)
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
          # The caught exception, if named (`rescue => e` / `rescue
          # Foo => e`), is a real local for the rescue body — found
          # 2026-07-18 alongside walk_identifier: without this, a bare
          # `e` reference inside the rescue body would now (correctly
          # for genuinely-unbound names, but wrongly here) resolve as
          # an implicit zero-arg method call attempt instead of the
          # local read it actually is. UnknownType since Adjutant has
          # no way to know the exception's real class here beyond
          # rescue_class's name (not itself resolved to a RubyClass by
          # this walker), same imprecision every other untyped binding
          # already carries.
          if rescue_var = node.rescue_var
            rescue_env[rescue_var] = UnknownType.new
          end
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
    # Mirrors walk_class's structure and bugs-fixed (see its own doc
    # comment): singleton defs go into `singleton_methods`, not
    # `@top_level_procs`; nested `class`/`module` statements register
    # themselves into `mod.constants` (mirroring the VM's `SetConstant`
    # under the enclosing self — see compile_class/compile_module),
    # which is what makes `M::A` resolvable as a ConstPath afterward.
    private def walk_module(node : ModuleNode) : RiskNode
      mod = RubyClass.new(node.name, nil, is_module: true)
      @known_classes[node.name] = mod

      children = node.body.stmts.map do |stmt|
        if stmt.is_a?(DefNode) && stmt.receiver.nil?
          register_class_method(mod, stmt)
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        elsif stmt.is_a?(DefNode) && stmt.receiver.is_a?(SelfNode)
          register_class_singleton_method(mod, stmt)
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        elsif stmt.is_a?(ClassNode) || stmt.is_a?(ModuleNode)
          walk_nested(stmt, mod)
        else
          walk_node(stmt, TypeInference::Env.new).as(RiskNode)
        end
      end
      RiskSequence.new(children, node.line)
    end

    # Walks a `class`/`module` statement nested directly inside another
    # class/module body, then registers the result under the
    # enclosing namespace's OWN constants table (RubyClass#constants) —
    # the piece walk_class/walk_module alone don't do, since each only
    # knows how to register itself into the flat @known_classes map.
    # Without this, `M::A` (a ConstPath) has nothing to resolve
    # against even though `A` alone is technically reachable via
    # @known_classes's flat namespace — real Ruby scoping requires the
    # lookup to go through M specifically.
    private def walk_nested(stmt : Node, enclosing : RubyClass) : RiskNode
      risk = walk_node(stmt, TypeInference::Env.new).as(RiskNode)
      name = stmt.is_a?(ClassNode) ? stmt.as(ClassNode).name : stmt.as(ModuleNode).name
      if nested = @known_classes[name]?
        sym_id = @interp.symbols.intern(name).value
        enclosing.constants[sym_id] = Value.rclass(nested)
      end
      risk
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
    # DefNode as a method on the RubyClass being built — an instance
    # method (`stmt.receiver.nil?`) into `cls`'s own `methods` table,
    # or a script singleton method (`def self.foo`, `stmt.receiver.
    # is_a?(SelfNode)`) into `cls`'s SEPARATE `singleton_methods`
    # table. Without this split, `def self.foo` would fall through to
    # the generic `walk_node`/`walk_def` path, which registers into
    # `@top_level_procs` — a real scope-crossing bug (silently
    # treating a class-scoped singleton method as a top-level
    # function), not just a missed case; `def obj.method` for any
    # OTHER receiver besides `self` remains genuinely unsupported (see
    # DEVELOPMENT.md) and falls through to walk_node like today. Any
    # bare call in the class body resolves against the ENCLOSING
    # scope's table (@top_level_procs, @known_classes as they stand at
    # this point in the walk) — a class body isn't its own top-level
    # scope.
    private def walk_class(node : ClassNode) : RiskNode
      superclass = node.superclass.try { |name| resolve_class(name) }
      cls = RubyClass.new(node.name, superclass)
      @known_classes[node.name] = cls

      children = node.body.stmts.map do |stmt|
        if stmt.is_a?(DefNode) && stmt.receiver.nil?
          register_class_method(cls, stmt)
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        elsif stmt.is_a?(DefNode) && stmt.receiver.is_a?(SelfNode)
          register_class_singleton_method(cls, stmt)
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        elsif stmt.is_a?(ClassNode) || stmt.is_a?(ModuleNode)
          walk_nested(stmt, cls)
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

    private def register_class_singleton_method(cls : RubyClass, node : DefNode) : Nil
      proc = ScriptProc.new(Chunk.new, node.name, node.params.map(&.name),
        ast_body: node.body, ast_params: node.params)
      sym_id = @interp.symbols.intern(node.name).value
      cls.define_singleton_method(sym_id, proc)
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
      elsif target.is_a?(Constant) && (value = node.value).is_a?(Lambda)
        # CONST = ->(){} — record the binding so a later CONST.call(...)
        # or some_fn(CONST) can resolve to this exact Lambda node. Only
        # trustworthy because Op::SetConstant now enforces assign-once
        # at runtime (see @known_constant_lambdas' own doc comment) —
        # walk_node above already walked node.value as a bare Lambda
        # (contributing nothing on its own, per walk_node's else
        # branch), so this doesn't double-walk the body; the body
        # itself is only ever actually walked lazily, on first
        # confirmed resolution, via walk_lambda_body's own cache.
        @known_constant_lambdas[target.name] = value
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

    private def walk_iterated(body : Body, env : TypeInference::Env, line : Int32, vars : Array(String) = [] of String) : RiskNode
      inner_env = env.dup
      # Real local bindings for THIS iteration's body — a `for`
      # loop's variable(s), or (via walk_call's block-folding) a
      # block's own params (`{ |x| ... }`). Found 2026-07-18 alongside
      # walk_identifier: without this, a bare reference to the loop/
      # block variable inside the body would now (correctly for
      # genuinely-unbound names, but wrongly here) resolve as an
      # implicit zero-arg method call attempt instead of the local
      # read it actually is. UnknownType, same imprecision every other
      # untyped binding already carries (no declared param/loop-var
      # types in Adjutant).
      vars.each { |name| inner_env[name] = UnknownType.new }
      node = walk_body(body, inner_env)
      RiskSequence.new([node.as(RiskNode)], line, iterated: true)
    end

    private def walk_call(node : Call, env : TypeInference::Env) : RiskNode
      # Every argument runs synchronously at THIS call site, regardless
      # of what the callee does with its value afterward — safe and
      # certain to fold in unconditionally, same footing as any other
      # expression in a Sequence. Found 2026-07-18 mid-Piece-D-design
      # (see SCOPE.md): args were never walked at all before this — a
      # plain risky call used as an argument (`puts(delete_file(...))`,
      # no lambda/block involved) was completely invisible.
      #
      # A `Lambda` LITERAL argument is a special case among these: its
      # own definition contributes nothing on its own (same as any
      # bare Lambda — see walk_node's else branch), but if the callee
      # is later confirmed to invoke it we can't tell here, so
      # walk_call_arg wraps a Lambda's walked body in RiskDeferred
      # rather than returning it plain — see walk_call_arg below.
      arg_risks = node.args.map { |arg| walk_call_arg(arg, env) }

      resolved = case receiver = node.receiver
                 when Nil
                   walk_receiverless_call(node)
                 when Constant
                   walk_class_receiver_call(node, resolve_class(receiver.name), receiver.name, receiver.name)
                 when ConstPath
                   walk_class_receiver_call(node, resolve_const_path(receiver), const_path_name(receiver), nil)
                 else
                   # The receiver expression itself runs unconditionally
                   # too, before the method it names even dispatches —
                   # same reasoning as args, just a single expression
                   # instead of an array of them.
                   receiver_risk = walk_node(receiver, env)
                   receiver_type = @inference.infer_node(receiver, env)
                   RiskSequence.new([receiver_risk, walk_receiver_call(node, receiver_type)], node.line)
                 end

      # A `{ }`/`do...end` block attached to this call folds into its
      # result unconditionally (unlike a Lambda argument — see
      # walk_call_arg): `yield` inside the callee's own body is a real,
      # statically-visible invocation contract, so unlike a lambda
      # merely handed off, a block genuinely runs as part of this call
      # (net Piece D judgment call: the callee might invoke it zero or
      # many times at runtime, same "can't statically bound how many
      # times" caveat walk_iterated already carries for while/for — but
      # "does it run at all" is confirmed here, unlike a passed lambda).
      # Walked with the ENCLOSING env (real closure semantics — a block
      # can read/write outer locals) rather than a fresh param-only
      # scope the way walk_lambda_body gives a Lambda literal.
      block_risk = node.block.try { |blk| walk_iterated(blk.body, env, blk.line, blk.params.map(&.name)) }

      children = [] of RiskNode
      children.concat(arg_risks)
      children << block_risk if block_risk
      children << resolved
      return resolved if children.size == 1
      RiskSequence.new(children, node.line)
    end

    # Walks a single call argument. An ordinary expression just gets
    # walk_node'd like any other value-producing expression. A Lambda
    # LITERAL gets special treatment: its body IS walkable (eagerly, so
    # the memo is populated and structural errors surface now — same
    # treatment walk_script_method gives a def's body), but whether the
    # callee actually invokes it isn't confirmed by anything visible
    # here (no yield-equivalent contract the way a BlockNode has), so
    # the walked body is wrapped RiskDeferred rather than folded in
    # unconditionally. A bare CONSTANT referencing a known lambda
    # binding (`F1 = ->(){}; apply(F1)`) gets the exact same treatment
    # as a literal — resolvable only because Op::SetConstant now
    # enforces assign-once, same reasoning as the CONST.call(...) case
    # in walk_class_receiver_call, but STILL wrapped RiskDeferred here
    # (not resolved directly the way CONST.call is): passing F1 as an
    # argument doesn't confirm the callee invokes it, unlike CONST.call
    # itself which IS the invocation. A plain (non-constant) variable
    # holding a lambda is NOT specially handled — falls through to
    # walk_node like any other expression, correctly RiskUnresolved-ish
    # via ordinary inference, since which literal a variable currently
    # holds is real aliasing the walker can't safely resolve.
    private def walk_call_arg(arg : Node, env : TypeInference::Env) : RiskNode
      if arg.is_a?(Lambda)
        RiskDeferred.new(walk_lambda_body(arg), "lambda literal passed as a call argument", arg.line)
      elsif arg.is_a?(Constant) && (lambda_node = @known_constant_lambdas[arg.name]?)
        RiskDeferred.new(walk_lambda_body(lambda_node), "constant-held lambda (#{arg.name}) passed as a call argument", arg.line)
      else
        walk_node(arg, env)
      end
    end

    # Walks a Lambda node's body eagerly, own-param-only scope (mirrors
    # walk_script_method's treatment of a def body — see class docs:
    # a proc's own body is walked using ONLY its own param scope, not
    # the caller's env, since Adjutant has no parameter type
    # declarations to do better with). Shared by walk_call_arg (Lambda
    # literal as an argument) and the constant-lambda .call resolution
    # in walk_class_receiver_call.
    private def walk_lambda_body(node : Lambda) : RiskNode
      if cached = @lambda_cache[node]?
        return cached
      end
      if @in_progress_lambdas.includes?(node)
        return RiskLeaf.new(RiskProfile.none, "<lambda> (recursive call)", node.line)
      end

      @in_progress_lambdas << node
      lambda_env = TypeInference::Env.new
      node.params.each { |param| lambda_env[param.name] = UnknownType.new }
      result = walk_body(node.body, lambda_env)
      @in_progress_lambdas.delete(node)
      @lambda_cache[node] = result
      result
    end

    # Render a ConstPath back to its dotted display form (`M::A`) for
    # RiskUnresolved/RiskLeaf labels — cosmetic only, doesn't affect
    # resolution.
    private def const_path_name(node : ConstPath) : String
      prefix = case ns = node.namespace
               when Constant  then ns.name
               when ConstPath then const_path_name(ns)
               else                "?"
               end
      "#{prefix}::#{node.name}"
    end

    # `ClassName.method(...)` for any method, not just `new` — the
    # receiver IS the class itself (already resolved by the caller,
    # from either a bare Constant or a ConstPath), so this resolves
    # against the class's own singleton tables
    # (RubyClass#find_singleton_method / #find_native_singleton_method),
    # never the instance method table. `.new` keeps its own dedicated
    # path (walk_constructor_call) since unlike an ordinary singleton
    # method it's also the one case with a generic, always-available
    # fallback (script `initialize`) when no native `new` is
    # registered. `display_name` is purely for RiskUnresolved/RiskLeaf
    # labels — resolution itself only depends on `cls`.
    private def walk_class_receiver_call(node : Call, cls : RubyClass?, display_name : String, const_name : String?) : RiskNode
      if node.method == "new"
        return walk_constructor_call(node, cls, display_name)
      end

      # CONST.call(...) where CONST is a known constant-held Lambda —
      # checked before the `unless cls` RiskUnresolved fallback below,
      # since this is exactly the case that fallback used to swallow
      # silently: `cls` is nil here (resolve_class's `.as_rclass?`
      # returns nil for a Proc-valued constant — it isn't a RubyClass
      # at all), so without this branch every CONST.call(...) would
      # read as an ordinary unresolved call, indistinguishable from a
      # truly-unknowable one. Piece D (SCOPE.md), found by the person:
      # unlike a Lambda passed onward as an ARGUMENT (see walk_call_arg
      # — wrapped RiskDeferred, since invocation there isn't confirmed),
      # invocation HERE is certain — `.call` is happening at this exact
      # call site, not handed off elsewhere — so this resolves directly
      # to the lambda's own walked-body risk, no RiskDeferred wrapper.
      # Only `.call` itself is special-cased; any other method name on
      # a Proc-valued constant (there are none today besides `call`/
      # `lambda?` — see builtins/proc.cr) still falls through to the
      # ordinary `unless cls` RiskUnresolved path below, correctly.
      if node.method == "call" && const_name && (lambda_node = @known_constant_lambdas[const_name]?)
        return walk_lambda_body(lambda_node)
      end

      return RiskUnresolved.new("#{display_name}.#{node.method}", node.line) unless cls

      sym = @interp.symbols.lookup(node.method)
      return RiskUnresolved.new("#{cls.name}.#{node.method}", node.line) unless sym

      if script_method = cls.find_singleton_method(sym.value)
        walk_script_method(script_method, node.line)
      elsif native = cls.find_native_singleton_method(sym.value)
        RiskLeaf.new(native.risk, "#{cls.name}.#{node.method}", node.line)
      else
        RiskUnresolved.new("#{cls.name}.#{node.method}", node.line)
      end
    end

    # `ClassName.new(...)` — mirrors TypeInference#infer_call's special
    # case. If the class (or an ancestor) registered a native
    # singleton `new` (see RubyClass#define_native_singleton_method —
    # a builtin like File allocating real state), resolve to THAT
    # method's real RiskProfile. Otherwise `.new` is the generic
    # script-`initialize` path, which carries no RiskProfile of its
    # own — treated as zero risk, same as before native singletons
    # existed.
    private def walk_constructor_call(node : Call, cls : RubyClass?, display_name : String) : RiskNode
      return RiskUnresolved.new("#{display_name}.new", node.line) unless cls

      if (sym = @interp.symbols.lookup("new")) && (native_new = cls.find_native_singleton_method(sym.value))
        RiskLeaf.new(native_new.risk, "#{cls.name}.new", node.line)
      else
        RiskSequence.new([] of RiskNode, node.line)
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
      walk_bare_name_call(node.method, node.line)
    end

    # Shared by walk_receiverless_call (an explicit `foo()`/`foo x` Call
    # node) and walk_identifier (a bare `foo` that turned out not to be
    # a known local — see walk_identifier's own comment). Both compile
    # to the exact same VM fallback (Op::GetGlobal falling through to
    # dispatch_call for an unresolved bare name — see vm.cr), so both
    # need the exact same static resolution: self's own methods first,
    # then native functions, then a top-level def seen so far, else
    # honestly unresolved.
    private def walk_bare_name_call(method : String, line : Int32) : RiskNode
      sym = @interp.symbols.lookup(method)
      if sym
        if native = @interp.native_callable(sym.value)
          return RiskLeaf.new(native.risk, method, line)
        end
        # A top-level def already executed via a PRIOR interp.eval
        # call — genuinely pre-existing, same footing as a native
        # function (see the comment above). Top-level defs live on
        # Object's own methods table now (Interpreter#main is a
        # RubyObject of class Object — see the 2026-07-16 root-scope
        # work), not @globals, so this checks main.rclass directly
        # rather than the removed @globals-ScriptProc lookup.
        if proc = @interp.main.rclass.find_method(sym.value)
          return walk_script_method(proc, line)
        end
      end
      if proc = @top_level_procs[method]?
        return walk_script_method(proc, line)
      end
      RiskUnresolved.new(method, line)
    end

    # A bare identifier (`delete_file`, no parens/args/block) is
    # genuinely ambiguous at parse time — real Ruby's own rule, which
    # Adjutant's compiler mirrors exactly (see compile_identifier):
    # a name already bound as a local/param wins; otherwise it's an
    # IMPLICIT ZERO-ARG METHOD CALL ATTEMPT (Op::GetGlobal falling
    # through to dispatch_call — see vm.cr). Found 2026-07-18 (via the
    # person's samples/risk_static_literal_lambda.rb): walk_node's
    # generic `else` branch previously treated EVERY bare Identifier as
    # a harmless value read, with no risk of its own — silently
    # invisible to the walker if the name was actually a risky
    # no-arg function called without parens. `env` (bindings seen so
    # far in THIS walk — params, earlier assignments) is the walker's
    # own equivalent of the compiler's `scope.resolve_local` check.
    private def walk_identifier(node : Identifier, env : TypeInference::Env) : RiskNode
      return RiskSequence.new([] of RiskNode, node.line) if env.has_key?(node.name)
      walk_bare_name_call(node.name, node.line)
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
