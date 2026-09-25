require "./ast"
require "./bytecode"
require "./risk_node"
require "./type_hint"
require "./type_inference"
require "./interpreter"

module Adjutant
  # Walks an AST into a RiskNode tree, resolving each call to the
  # risk profile of the native callable or script method it reaches.
  #
  #   1. Receiver types come from TypeInference, run alongside the
  #      walk on the same Env.
  #   2. A script method's body is walked once, with every parameter
  #      of unknown type, and the result is memoized per ScriptProc, so
  #      its risk doesn't depend on the call site. `def process(f);
  #      f.read; end` never learns what `f` is; see DEVELOPMENT.md,
  #      "Structured risk".
  #   3. A call to a method already being walked (recursion) becomes a
  #      leaf marked "recursive call", escalated like a loop, since
  #      neither can be bounded statically.
  class RiskWalker
    # Top-level defs seen so far, in walk order: a call before its
    # def is unresolved, as it would be a NameError at runtime.
    @top_level_procs : Hash(String, ScriptProc)

    # Classes defined so far, in walk order. Calls between a class's
    # own methods resolve whatever their order, since methods run
    # only after the class body has finished.
    @known_classes : Hash(String, RubyClass)

    # Constants bound to a lambda literal, so `F.call` and `f(F)`
    # can resolve to its body. Trustworthy because constants are
    # assign-once at runtime.
    @known_constant_lambdas : Hash(String, Lambda)

    # The class whose method body is being walked, so a bare call to
    # a sibling method (`second` inside `first`) resolves against it.
    # Nil at top level and in a lambda.
    @current_self_class : RubyClass?

    # Whether that method is a singleton method (`def self.foo`), whose
    # bare sibling calls resolve against the singleton tables.
    @current_self_is_singleton : Bool = false

    # The method being walked, whose name `super` needs; nil outside
    # a method body.
    @current_method_proc : ScriptProc?

    def initialize(@interp : Interpreter)
      @inference = TypeInference.new(@interp)
      @method_cache = {} of ScriptProc => RiskNode
      @in_progress = Set(ScriptProc).new
      # Memo and recursion guard for lambda bodies, keyed by the
      # Lambda node. A constant-held lambda can call itself
      # (`F = ->() { F.call }`).
      @lambda_cache = {} of Lambda => RiskNode
      @in_progress_lambdas = Set(Lambda).new
      @top_level_procs = {} of String => ScriptProc
      @known_classes = {} of String => RubyClass
      @known_constant_lambdas = {} of String => Lambda
      @inference.class_resolver = ->(name : String) { resolve_class(name) }
      @inference.const_path_resolver = ->(node : ConstPath) { resolve_const_path(node) }
    end

    # Classes the walk has defined first, then the interpreter's:
    # builtins and classes from an earlier `eval`.
    private def resolve_class(name : String) : RubyClass?
      @known_classes[name]? || @interp.get_global(name).as_rclass?
    end

    # Resolves `M::A` or `M::N::A` through each namespace's own
    # constants, as Op::GetConstantFrom does at runtime.
    private def resolve_const_path(node : ConstPath) : RubyClass?
      ns = node.namespace
      owner = case ns
              when Constant  then resolve_class(ns.name)
              when ConstPath then resolve_const_path(ns)
              end
      return unless owner
      sym = @interp.symbols.lookup(node.name)
      return unless sym
      owner.constants[sym.value]?.try(&.as_rclass?)
    end

    # Entry point for a top-level script body.
    def walk_body(body : Body, env : TypeInference::Env = TypeInference::Env.new) : RiskNode
      children = body.stmts.map { |stmt| walk_node(stmt, env).as(RiskNode) }
      RiskSequence.new(children, body.line)
    end

    # One case per node kind.
    def walk_node(node : Node, env : TypeInference::Env) : RiskNode
      case node
      when IfNode, UnlessNode, CaseNode, WhileNode, LoopNode, ForNode, ModifierIf, ModifierWhile, BeginNode
        walk_control_flow(node, env)
      when Assign, OpAssign, CondAssign, MultiAssign, IndexAssign, AttrAssign
        walk_assignment(node, env)
      when Call       then walk_call(node, env)
      when SuperNode  then walk_super(node, env)
      when Identifier then walk_identifier(node, env)
      when Body       then walk_body(node, env)
      when DefNode    then walk_def(node)
      when ClassNode  then walk_class(node)
      when ModuleNode then walk_module(node)
      when ArrayLiteral, HashLiteral
        walk_collection_literal(node, env)
      else
        # No risk of its own; inferred so the Env stays current.
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
      when AttrAssign  then walk_attr_assign(node, env)
      else                  RiskSequence.new([] of RiskNode, node.line)
      end
    end

    # `unless`: a Choice, as for `if`. Unlike `walk_if`, branch
    # bindings are not merged into the Env, so they read as unknown
    # afterwards.
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

    # `expr if cond` and `expr unless cond`: a Choice between running
    # `expr` once and not at all.
    private def walk_modifier_if(node : ModifierIf, env : TypeInference::Env) : RiskNode
      body_env = env.dup
      body_risk = walk_node(node.body, body_env)
      RiskChoice.new([body_risk, RiskSequence.new([] of RiskNode, node.line)] of RiskNode,
        node.negated? ? "unless" : "if", node.line)
    end

    # `expr while cond` and `expr until cond`: an unknown number of
    # repeats, as for `while`.
    private def walk_modifier_while(node : ModifierWhile, env : TypeInference::Env) : RiskNode
      inner_env = env.dup
      body_risk = walk_node(node.body, inner_env)
      RiskSequence.new([body_risk] of RiskNode, node.line, iterated: true)
    end

    # A Choice between the body (then `else`) and each rescue clause,
    # followed by the ensure body. Without rescue clauses, a plain
    # Sequence.
    private def walk_begin(node : BeginNode, env : TypeInference::Env) : RiskNode
      body_env = env.dup
      body_risk = walk_body(node.body, body_env)

      # `else` runs only after the body succeeded, so it continues
      # from the body's Env; a rescue or ensure branch starts from the
      # outer Env, since the body may have stopped anywhere.
      success_risk =
        if else_body = node.else_body
          RiskSequence.new([body_risk, walk_body(else_body, body_env.dup)] of RiskNode, node.line)
        else
          body_risk
        end

      try_result =
        if node.rescue_clauses.empty?
          success_risk
        else
          branches = [success_risk] of RiskNode
          node.rescue_clauses.each do |clause|
            rescue_env = env.dup
            # `rescue => e` binds `e` as a local of unknown type, so
            # it isn't mistaken for a method call.
            if rescue_var = clause.var
              rescue_env[rescue_var] = UnknownType.new
            end
            branches << walk_body(clause.body, rescue_env)
          end
          # Exactly one branch runs.
          RiskChoice.new(branches, "rescue", node.line)
        end

      if ensure_body = node.ensure_body
        ensure_env = env.dup
        ensure_risk = walk_body(ensure_body, ensure_env)
        RiskSequence.new([try_result, ensure_risk] of RiskNode, node.line)
      else
        try_result
      end
    end

    # A `module` statement, walked as `walk_class` walks a class:
    # singleton defs go to `singleton_methods`, and nested classes and
    # modules register in its `constants`, so `M::A` resolves.
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
        elsif include_call?(stmt)
          register_static_include(mod, stmt.as(Call))
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        elsif extend_call?(stmt)
          register_static_extend(mod, stmt.as(Call))
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        else
          walk_node(stmt, TypeInference::Env.new).as(RiskNode)
        end
      end
      RiskSequence.new(children, node.line)
    end

    # Walks a class or module statement inside `enclosing`'s body and
    # registers it in `enclosing.constants`, so `M::A` resolves
    # through `M`.
    private def walk_nested(stmt : Node, enclosing : RubyClass) : RiskNode
      risk = walk_node(stmt, TypeInference::Env.new).as(RiskNode)
      name = stmt.is_a?(ClassNode) ? stmt.as(ClassNode).name : stmt.as(ModuleNode).name
      if nested = @known_classes[name]?
        sym_id = @interp.symbols.intern(name).value
        enclosing.constants[sym_id] = Value.rclass(nested)
      end
      risk
    end

    # A `def` registers a method and has no risk; the body is walked
    # on first call. The ScriptProc's chunk is empty, since walked
    # procs never run.
    private def walk_def(node : DefNode) : RiskNode
      proc = ScriptProc.new(Chunk.new, node.name, node.params.map(&.name),
        ast_body: node.body, ast_params: node.params)
      @top_level_procs[node.name] = proc
      RiskSequence.new([] of RiskNode, node.line)
    end

    # Whether `stmt` is a bare `include Module`, the only form the
    # walk mirrors; `Foo.include(M)` is not recognized, as the native
    # `include` doesn't accept it either.
    private def include_call?(stmt : Node) : Bool
      stmt.is_a?(Call) && stmt.receiver.nil? && stmt.method == "include" && stmt.args.size == 1
    end

    # `include_call?` for `extend`.
    private def extend_call?(stmt : Node) : Bool
      stmt.is_a?(Call) && stmt.receiver.nil? && stmt.method == "extend" && stmt.args.size == 1
    end

    # Mirrors `include SomeModule` into the class being walked, so
    # methods reached through the module resolve. The call itself is
    # structural, like `def`, so contributes no risk and isn't walked
    # as a call. Does nothing if the module isn't known to the walk,
    # such as one a native `require` defines.
    private def register_static_include(cls : RubyClass, node : Call) : Nil
      arg = node.args.first
      mod = case arg
            when Constant  then resolve_class(arg.name)
            when ConstPath then resolve_const_path(arg)
            end
      cls.include_module(mod) if mod
    end

    # `register_static_include` for `extend`.
    private def register_static_extend(cls : RubyClass, node : Call) : Nil
      arg = node.args.first
      mod = case arg
            when Constant  then resolve_class(arg.name)
            when ConstPath then resolve_const_path(arg)
            end
      cls.extend_module(mod) if mod
    end

    # A `class` statement: its body runs at once, like top-level code.
    # Instance and singleton defs register on the class, nested
    # classes and modules in its constants, and `include`/`extend`
    # are mirrored; other statements are walked, resolving bare calls
    # against the enclosing scope. `def obj.method` for another
    # receiver is not supported.
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
        elsif include_call?(stmt)
          register_static_include(cls, stmt.as(Call))
          RiskSequence.new([] of RiskNode, stmt.line).as(RiskNode)
        elsif extend_call?(stmt)
          register_static_extend(cls, stmt.as(Call))
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
      # `walk_super_target` searches ancestors from here.
      proc.lexical_scope = cls
      sym_id = @interp.symbols.intern(node.name).value
      cls.define_method(sym_id, proc)
    end

    private def register_class_singleton_method(cls : RubyClass, node : DefNode) : Nil
      proc = ScriptProc.new(Chunk.new, node.name, node.params.map(&.name),
        ast_body: node.body, ast_params: node.params)
      proc.lexical_scope = cls
      sym_id = @interp.symbols.intern(node.name).value
      cls.define_singleton_method(sym_id, proc)
    end

    # An assignment's value is walked for risk as well as inferred:
    # `f = fetch(url)` runs the call.
    private def walk_assign(node : Assign, env : TypeInference::Env) : RiskNode
      value_risk = walk_node(node.value, env)
      # Records the binding for later siblings.
      value_type = @inference.infer_node(node.value, env)
      if (target = node.target).is_a?(Identifier)
        env[target.name] = value_type
      elsif target.is_a?(Constant) && (value = node.value).is_a?(Lambda)
        # `CONST = ->(){}`: recorded so later calls through the
        # constant resolve to this lambda. Its body is walked on first
        # resolved call, not here.
        @known_constant_lambdas[target.name] = value
      end
      value_risk
    end

    # `x += expr`: `expr` is walked for risk. The target's type after
    # the operation isn't tracked, so it reads as unknown.
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

    # `a, b = 1, 2`: each value is walked in order. Targets aren't
    # type-tracked, so they read as unknown.
    private def walk_multi_assign(node : MultiAssign, env : TypeInference::Env) : RiskNode
      children = node.values.map { |value| walk_node(value, env).as(RiskNode) }
      node.targets.each do |target|
        env.delete(target.name) if target.is_a?(Identifier)
      end
      RiskSequence.new(children, node.line)
    end

    # `arr[i] = expr`: target, index and value are each walked, in
    # order.
    private def walk_index_assign(node : IndexAssign, env : TypeInference::Env) : RiskNode
      children = [
        walk_node(node.target, env).as(RiskNode),
        walk_node(node.index, env).as(RiskNode),
        walk_node(node.value, env).as(RiskNode),
      ]
      RiskSequence.new(children, node.line)
    end

    # `recv.attr = value`: the receiver and value are walked. The
    # setter call adds no risk here: a native receiver has no setters,
    # and a script setter's body is walked with its def.
    private def walk_attr_assign(node : AttrAssign, env : TypeInference::Env) : RiskNode
      children = [
        walk_node(node.receiver, env).as(RiskNode),
        walk_node(node.value, env).as(RiskNode),
      ]
      RiskSequence.new(children, node.line)
    end

    # `[a, b]` and `{k => v}`: every element, key and value is
    # walked, in order.
    private def walk_collection_literal(node : Node, env : TypeInference::Env) : RiskNode
      children =
        case node
        when ArrayLiteral
          node.elements.map { |elem| walk_node(elem, env).as(RiskNode) }
        when HashLiteral
          node.pairs.flat_map { |k, v| [walk_node(k, env).as(RiskNode), walk_node(v, env).as(RiskNode)] }
        else
          [] of RiskNode
        end
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

      # Merges branch bindings into the Env for later siblings.
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
      # The loop variables or block parameters, bound as locals of
      # unknown type.
      vars.each { |name| inner_env[name] = UnknownType.new }
      node = walk_body(body, inner_env)
      RiskSequence.new([node.as(RiskNode)], line, iterated: true)
    end

    # `super(...)`: its explicit arguments, then what it reaches.
    # Bare `super` forwards parameters, which are local reads with no
    # risk of their own.
    private def walk_super(node : SuperNode, env : TypeInference::Env) : RiskNode
      arg_risks = node.args.map { |arg| walk_call_arg(arg, env) }
      resolved = walk_super_target(node)
      children = arg_risks + [resolved]
      return resolved if children.size == 1
      RiskSequence.new(children, node.line)
    end

    # Resolves what `super` reaches, as `VM#dispatch_super` does:
    # the current method's name, searched in self's ancestors after the
    # method's lexical scope. Unresolved outside a method body.
    private def walk_super_target(node : SuperNode) : RiskNode
      cls = @current_self_class
      proc = @current_method_proc
      return RiskUnresolved.new("super", node.line) unless cls && proc
      lex = proc.lexical_scope
      return RiskUnresolved.new("super", node.line) unless lex
      sym = @interp.symbols.lookup(proc.name)
      return RiskUnresolved.new("super", node.line) unless sym

      # A singleton method's `super` searches other tables.
      return walk_super_singleton(node, cls, lex, sym, proc) if @current_self_is_singleton

      chain = cls.ancestors
      idx = chain.index(lex)
      return RiskUnresolved.new("super", node.line) unless idx

      chain[(idx + 1)..].each do |candidate|
        if script_method = candidate.methods[sym.value]?
          return walk_script_method(script_method, node.line, cls)
        end
        if native = candidate.native_methods[sym.value]?
          return RiskLeaf.new(native.risk, proc.name, node.line)
        end
      end
      RiskUnresolved.new("super", node.line)
    end

    # `walk_super_target` for a singleton method: searches
    # `RubyClass#singleton_ancestors`, where each entry says which table
    # to check.
    private def walk_super_singleton(node : SuperNode, cls : RubyClass, lex : RubyClass,
                                     sym : Sym, proc : ScriptProc) : RiskNode
      chain = cls.singleton_ancestors
      idx = chain.index { |(candidate, _)| candidate == lex }
      return RiskUnresolved.new("super", node.line) unless idx

      chain[(idx + 1)..].each do |(candidate, use_singleton_table)|
        if use_singleton_table
          if script_method = candidate.singleton_methods[sym.value]?
            return walk_script_method(script_method, node.line, cls, is_singleton: true)
          end
          if native = candidate.native_singleton_methods[sym.value]?
            return RiskLeaf.new(native.risk, proc.name, node.line)
          end
        else
          if script_method = candidate.methods[sym.value]?
            return walk_script_method(script_method, node.line, cls, is_singleton: true)
          end
          if native = candidate.native_methods[sym.value]?
            return RiskLeaf.new(native.risk, proc.name, node.line)
          end
        end
      end
      RiskUnresolved.new("super", node.line)
    end

    private def walk_call(node : Call, env : TypeInference::Env) : RiskNode
      # Positional and keyword argument values run at this call site,
      # so their risk folds in. A lambda literal argument is deferred;
      # see `walk_call_arg`.
      arg_risks = node.args.map { |arg| walk_call_arg(arg, env) } +
                  node.kwargs.map { |(_, value)| walk_call_arg(value, env) }

      resolved = case receiver = node.receiver
                 when Nil
                   walk_receiverless_call(node)
                 when Constant
                   walk_class_receiver_call(node, resolve_class(receiver.name), receiver.name, receiver.name)
                 when ConstPath
                   walk_class_receiver_call(node, resolve_const_path(receiver), const_path_name(receiver), nil)
                 else
                   # The receiver expression runs first.
                   receiver_risk = walk_node(receiver, env)
                   receiver_type = @inference.infer_node(receiver, env)
                   RiskSequence.new([receiver_risk, walk_receiver_call(node, receiver_type)], node.line)
                 end

      # An attached block folds in as an iterated body: the callee
      # may yield to it any number of times. It closes over the
      # enclosing Env, unlike a lambda body.
      block_risk = node.block.try { |blk| walk_iterated(blk.body, env, blk.line, blk.params.map(&.name)) }

      children = [] of RiskNode
      children.concat(arg_risks)
      children << block_risk if block_risk
      children << resolved
      return resolved if children.size == 1
      RiskSequence.new(children, node.line)
    end

    # Walks one call argument. A lambda literal, or a constant bound
    # to one, is walked but wrapped in RiskDeferred, since passing it
    # doesn't show the callee calls it. A variable holding a lambda is
    # an ordinary expression: which lambda it holds can't be known.
    private def walk_call_arg(arg : Node, env : TypeInference::Env) : RiskNode
      if arg.is_a?(Lambda)
        RiskDeferred.new(walk_lambda_body(arg), "lambda literal passed as a call argument", arg.line)
      elsif arg.is_a?(Constant) && (lambda_node = @known_constant_lambdas[arg.name]?)
        RiskDeferred.new(walk_lambda_body(lambda_node), "constant-held lambda (#{arg.name}) passed as a call argument", arg.line)
      else
        walk_node(arg, env)
      end
    end

    # Walks a lambda's body with only its own parameters in scope, as
    # for a method body. Memoized and guarded against recursion.
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

    # `M::A`, for labels only.
    private def const_path_name(node : ConstPath) : String
      prefix = case ns = node.namespace
               when Constant  then ns.name
               when ConstPath then const_path_name(ns)
               else                "?"
               end
      "#{prefix}::#{node.name}"
    end

    # `ClassName.method(...)`: resolved against the class's singleton
    # tables. `.new` goes to `walk_constructor_call`. `display_name` is
    # for labels only.
    private def walk_class_receiver_call(node : Call, cls : RubyClass?, display_name : String, const_name : String?) : RiskNode
      if node.method == "new"
        return walk_constructor_call(node, cls, display_name)
      end

      # `CONST.call(...)` on a constant bound to a lambda: the call is
      # certain here, so the lambda's body risk folds in directly.
      # Checked before the unresolved fallback, since `cls` is nil for
      # a Proc-valued constant.
      if node.method == "call" && const_name && (lambda_node = @known_constant_lambdas[const_name]?)
        return walk_lambda_body(lambda_node)
      end

      return RiskUnresolved.new("#{display_name}.#{node.method}", node.line) unless cls

      sym = @interp.symbols.lookup(node.method)
      return RiskUnresolved.new("#{cls.name}.#{node.method}", node.line) unless sym

      if script_method = cls.find_singleton_method(sym.value)
        walk_script_method(script_method, node.line, cls, is_singleton: true)
      elsif native = cls.find_native_singleton_method(sym.value)
        RiskLeaf.new(native.risk, "#{cls.name}.#{node.method}", node.line)
      else
        RiskUnresolved.new("#{cls.name}.#{node.method}", node.line)
      end
    end

    # `ClassName.new(...)`: a native `new`'s risk profile if the class
    # or an ancestor has one; otherwise a script `initialize`, which
    # adds no risk here.
    private def walk_constructor_call(node : Call, cls : RubyClass?, display_name : String) : RiskNode
      return RiskUnresolved.new("#{display_name}.new", node.line) unless cls

      if (sym = @interp.symbols.lookup("new")) && (native_new = cls.find_native_singleton_method(sym.value))
        RiskLeaf.new(native_new.risk, "#{cls.name}.new", node.line)
      else
        RiskSequence.new([] of RiskNode, node.line)
      end
    end

    # `some_fn(args)`, resolved by `walk_bare_name_call`.
    private def walk_receiverless_call(node : Call) : RiskNode
      walk_bare_name_call(node.method, node.line)
    end

    # Resolves a bare call against self's class first, as
    # `dispatch_call` does, using the singleton tables in a singleton
    # method. Nil when self's class doesn't have it, so the caller can
    # keep looking.
    private def walk_current_class_bare_call(sym_id : Int32, method : String, line : Int32) : RiskNode?
      return unless cls = @current_self_class
      if @current_self_is_singleton
        if script_method = cls.find_singleton_method(sym_id)
          return walk_script_method(script_method, line, cls, is_singleton: true)
        end
        if native = cls.find_native_singleton_method(sym_id)
          return RiskLeaf.new(native.risk, method, line)
        end
      else
        if script_method = cls.find_method(sym_id)
          return walk_script_method(script_method, line, cls)
        end
        if native = cls.find_native_method(sym_id)
          return RiskLeaf.new(native.risk, method, line)
        end
      end
      nil
    end

    # Resolves a bare call, as `dispatch_call` would: self's class
    # (which reaches Object, so native functions and executed
    # top-level defs), then defs seen so far in this walk, else
    # unresolved.
    private def walk_bare_name_call(method : String, line : Int32) : RiskNode
      sym = @interp.symbols.lookup(method)
      if sym
        if resolved = walk_current_class_bare_call(sym.value, method, line)
          return resolved
        end
        if native = @interp.native_callable(sym.value)
          return RiskLeaf.new(native.risk, method, line)
        end
        # A top-level def from an earlier `eval`: a method of Object.
        if proc = @interp.main.rclass.find_method(sym.value)
          return walk_script_method(proc, line)
        end
      end
      if proc = @top_level_procs[method]?
        return walk_script_method(proc, line)
      end
      RiskUnresolved.new(method, line)
    end

    # A bare identifier is a local if the Env binds it, otherwise an
    # implicit zero-argument call, as the compiler decides.
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

    # A receiver whose type is a union: the call resolves against each
    # possible class, as a Choice.
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
        walk_script_method(script_method, node.line, cls)
      elsif native = cls.find_native_method(sym.value)
        RiskLeaf.new(native.risk, "#{cls.name}##{node.method}", node.line)
      else
        RiskUnresolved.new("#{cls.name}##{node.method}", node.line)
      end
    end

    # Walks a script method's body with only its own parameters in
    # scope. Memoized per ScriptProc; guarded against recursion.
    private def walk_script_method(proc : ScriptProc, call_line : Int32, self_class : RubyClass? = nil, is_singleton : Bool = false) : RiskNode
      if cached = @method_cache[proc]?
        return cached
      end
      if @in_progress.includes?(proc)
        return RiskLeaf.new(RiskProfile.none, "#{proc.name} (recursive call)", call_line)
      end

      ast_body = proc.ast_body
      unless ast_body
        # No AST to walk, as for a ScriptProc built straight from a
        # Chunk: unresolved rather than assumed safe.
        return RiskUnresolved.new("#{proc.name} (no AST available)", call_line)
      end

      @in_progress << proc
      # Saved and restored, so nested and recursive walks each see
      # their own method's class.
      previous_self_class = @current_self_class
      previous_is_singleton = @current_self_is_singleton
      previous_method_proc = @current_method_proc
      @current_self_class = self_class
      @current_self_is_singleton = is_singleton
      @current_method_proc = proc
      method_env = TypeInference::Env.new
      proc.params.each { |param| method_env[param] = UnknownType.new }
      result = walk_body(ast_body, method_env)
      @current_self_class = previous_self_class
      @current_self_is_singleton = previous_is_singleton
      @current_method_proc = previous_method_proc
      @in_progress.delete(proc)
      @method_cache[proc] = result
      result
    end
  end
end
