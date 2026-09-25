require "./ast"
require "./type_hint"
require "./interpreter"

module Adjutant
  # Infers types of AST nodes without running the script, enough for
  # the risk walker to resolve receivers. Local variables only:
  #
  #   1. Integer, Array and Hash literals, and `ClassName.new(...)`,
  #      have a known type; other literals and call results are
  #      unknown.
  #   2. A local's type follows its assignments in order; a parameter
  #      or unassigned name is unknown.
  #   3. `if` and `case` branches are inferred on copies of the Env
  #      and merged with `TypeHint.merge`.
  #   4. A loop body is inferred once and merged with the Env from
  #      before it, standing in for zero or more passes.
  class TypeInference
    # Literal node classes with a known builtin type.
    BUILTIN_CLASS_NAMES = {
      IntLiteral   => "Integer",
      ArrayLiteral => "Array",
      HashLiteral  => "Hash",
    }

    alias Env = Hash(String, TypeHint)

    # Resolves a class name for `ClassName.new`. Defaults to the
    # interpreter's classes; RiskWalker adds the classes it has
    # defined during its walk.
    property class_resolver : String -> RubyClass?

    # `class_resolver` for `M::A.new`. The default walks the
    # interpreter's constants, as Op::GetConstantFrom does.
    property const_path_resolver : ConstPath -> RubyClass?

    def initialize(@interp : Interpreter)
      @class_resolver = ->(name : String) { @interp.get_global(name).as_rclass? }
      @const_path_resolver = ->(node : ConstPath) { default_resolve_const_path(node) }
    end

    # The default `const_path_resolver`. A method, since a Proc in
    # `initialize` can't call `@const_path_resolver` before the ivar
    # is assigned.
    private def default_resolve_const_path(node : ConstPath) : RubyClass?
      ns = node.namespace
      owner = case ns
              when Constant  then @interp.get_global(ns.name).as_rclass?
              when ConstPath then default_resolve_const_path(ns)
              end
      sym = owner ? @interp.symbols.lookup(node.name) : nil
      (owner && sym) ? owner.constants[sym.value]?.try(&.as_rclass?) : nil
    end

    # Infers each statement in order; returns the last one's type and
    # the final Env. For a hint per node, call `infer_node`.
    def infer_body(body : Body, env : Env) : {TypeHint, Env}
      result : TypeHint = UnknownType.new
      body.stmts.each do |stmt|
        result = infer_node(stmt, env)
      end
      {result, env}
    end

    # Infers one node's type. An assignment updates `env` in place,
    # so later siblings see it.
    def infer_node(node : Node, env : Env) : TypeHint
      case node
      when IfNode, CaseNode, WhileNode, LoopNode
        infer_control_flow(node, env)
      else
        infer_simple(node, env)
      end
    end

    private def infer_control_flow(node : Node, env : Env) : TypeHint
      case node
      when IfNode    then infer_if(node, env)
      when CaseNode  then infer_case(node, env)
      when WhileNode then infer_loop(node.body, env)
      when LoopNode  then infer_loop(node.body, env)
      else                UnknownType.new
      end
    end

    private def infer_simple(node : Node, env : Env) : TypeHint
      case node
      when IntLiteral   then known_builtin(IntLiteral)
      when ArrayLiteral then known_builtin(ArrayLiteral)
      when HashLiteral  then known_builtin(HashLiteral)
      when Identifier   then env[node.name]? || UnknownType.new
      when Assign       then infer_assign(node, env)
      when Call         then infer_call(node, env)
      when Body         then infer_body(node, env)[0]
      else                   UnknownType.new
      end
    end

    private def known_builtin(node_class) : TypeHint
      name = BUILTIN_CLASS_NAMES[node_class]?
      return UnknownType.new unless name
      cls = @interp.get_global(name).as_rclass?
      cls ? KnownType.new(cls) : UnknownType.new
    end

    private def infer_assign(node : Assign, env : Env) : TypeHint
      value_type = infer_node(node.value, env)
      if (target = node.target).is_a?(Identifier)
        env[target.name] = value_type
      end
      value_type
    end

    # Only `ClassName.new(...)` and `M::A.new(...)` have a known type.
    private def infer_call(node : Call, env : Env) : TypeHint
      receiver = node.receiver
      return UnknownType.new unless node.method == "new"
      cls = case receiver
            when Constant  then @class_resolver.call(receiver.name)
            when ConstPath then @const_path_resolver.call(receiver)
            end
      cls ? KnownType.new(cls) : UnknownType.new
    end

    # Infers each branch on its own copy of `env` and merges them
    # back. A variable a branch doesn't touch keeps its earlier type
    # there. Public so RiskWalker can keep its Env in step.
    def infer_if(node : IfNode, env : Env) : TypeHint
      branch_envs = [] of Env
      branch_types = [] of TypeHint

      then_env = env.dup
      branch_types << infer_body(node.then_branch, then_env)[0]
      branch_envs << then_env

      node.elsif_branches.each do |(cond, body)|
        b_env = env.dup
        branch_types << infer_body(body, b_env)[0]
        branch_envs << b_env
      end

      if else_branch = node.else_branch
        else_env = env.dup
        branch_types << infer_body(else_branch, else_env)[0]
        branch_envs << else_env
      else
        # Without an `else`, skipping every branch is an outcome too.
        branch_envs << env.dup
      end

      merge_envs_into(env, branch_envs)
      branch_types.reduce(UnknownType.new.as(TypeHint)) { |merged, branch_type| TypeHint.merge(merged, branch_type) }
    end

    def infer_case(node : CaseNode, env : Env) : TypeHint
      branch_envs = [] of Env
      branch_types = [] of TypeHint

      node.whens.each do |(_conds, body)|
        b_env = env.dup
        branch_types << infer_body(body, b_env)[0]
        branch_envs << b_env
      end

      if else_branch = node.else_branch
        else_env = env.dup
        branch_types << infer_body(else_branch, else_env)[0]
        branch_envs << else_env
      else
        branch_envs << env.dup
      end

      merge_envs_into(env, branch_envs)
      branch_types.reduce(UnknownType.new.as(TypeHint)) { |merged, branch_type| TypeHint.merge(merged, branch_type) }
    end

    # Merges the Env before the loop with the Env after one pass.
    private def infer_loop(body : Body, env : Env) : TypeHint
      after_env = env.dup
      infer_body(body, after_env)
      merge_envs_into(env, [env.dup, after_env])
      UnknownType.new
    end

    # Merges `branch_envs` into `env`: a variable present in every
    # branch merges with `TypeHint.merge`; one missing from any branch
    # is dropped, so reads as unknown.
    private def merge_envs_into(env : Env, branch_envs : Array(Env)) : Nil
      return if branch_envs.empty?
      all_keys = branch_envs.flat_map(&.keys).uniq!
      all_keys.each do |key|
        hints = branch_envs.map { |branch_env| branch_env[key]? }
        if hints.all?
          env[key] = hints.compact.reduce { |merged, hint| TypeHint.merge(merged, hint) }
        else
          env.delete(key)
        end
      end
    end
  end
end
