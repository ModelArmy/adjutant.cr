require "./ast"
require "./type_hint"
require "./interpreter"

module Adjutant
  # Infers a TypeHint for AST nodes without running the script — a
  # minimal pass, not full Hindley-Milner. Scope, deliberately:
  #
  #   - Literals with a real builtin RubyClass today (IntLiteral →
  #     Integer) resolve to KnownType. Literals whose builtin isn't
  #     implemented yet (String, Array, ...) fall through to
  #     UnknownType until those land — see BUILTIN_CLASS_NAMES below,
  #     which is the single place to extend as more builtins exist.
  #   - `ClassName.new(...)` resolves to KnownType({ClassName}) — a
  #     real, cheap win: constructor calls are syntactically obvious
  #     without any return-type declarations existing in the language.
  #   - A local var's type is tracked linearly through a Body's
  #     statements; reassignment updates it; reading before any
  #     assignment (params included) is UnknownType.
  #   - if/case: each branch is inferred against a COPY of the
  #     incoming env; per-var results are merged via TypeHint.merge
  #     after — a var assigned the same known type in every branch
  #     stays Known; anything else (including a branch that never
  #     touches it) merges down per TypeHint.merge's rules.
  #   - Loops: body is inferred once against current env, then merged
  #     back into it — approximates "after N iterations" as a 2-way
  #     merge (0 vs. 1 pass), same shape as if/else.
  #   - Any other node (unresolved call return, ivar, etc.) is
  #     UnknownType. No attempt to track ivars/cvars/globals in this
  #     pass — only local vars, which is what the risk walker's
  #     nearest-term need (resolving `f = File.new; f.read`) requires.
  class TypeInference
    # AST-literal-node-name → builtin RubyClass name. Extend this as
    # more builtins land (String, Array, ...) — everything else about
    # the pass stays the same.
    BUILTIN_CLASS_NAMES = {
      IntLiteral => "Integer",
    }

    alias Env = Hash(String, TypeHint)

    # Resolves a class name to a RubyClass for `ClassName.new(...)`
    # inference. Defaults to the interpreter's live globals (already-
    # executed classes) — RiskWalker overrides this to ALSO see
    # classes it has built for itself while walking a not-yet-executed
    # script, since those don't exist in @interp's globals at all.
    property class_resolver : String -> RubyClass?

    def initialize(@interp : Interpreter)
      @class_resolver = ->(name : String) { @interp.get_global(name).as_rclass? }
    end

    # Infers types through a Body's statements, returning the type of
    # the Body's last expression (its implicit return value) alongside
    # the final env — callers that need per-node hints (the risk
    # walker) should call `infer_node` directly per node instead.
    def infer_body(body : Body, env : Env) : {TypeHint, Env}
      result : TypeHint = UnknownType.new
      body.stmts.each do |stmt|
        result = infer_node(stmt, env)
      end
      {result, env}
    end

    # Infers a single node's TypeHint, mutating `env` in place for
    # Assign nodes (so subsequent siblings in the same Body see the
    # updated binding).
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
      when IntLiteral then known_builtin(IntLiteral)
      when Identifier then env[node.name]? || UnknownType.new
      when Assign     then infer_assign(node, env)
      when Call       then infer_call(node, env)
      when Body       then infer_body(node, env)[0]
      else                 UnknownType.new
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

    # `ClassName.new(...)` — the one call shape resolvable without any
    # return-type system: a literal Constant receiver calling `new`.
    private def infer_call(node : Call, env : Env) : TypeHint
      receiver = node.receiver
      if receiver.is_a?(Constant) && node.method == "new"
        cls = @class_resolver.call(receiver.name)
        return cls ? KnownType.new(cls) : UnknownType.new
      end
      UnknownType.new
    end

    # Each branch gets its own env copy; per-variable results are
    # merged afterward via TypeHint.merge. A var untouched by a branch
    # keeps its pre-branch type from that branch's copy, so "only
    # touched in one arm" naturally merges with its own prior value
    # rather than spuriously degrading to Unknown.
    # Public: RiskWalker calls these directly to keep TypeInference's
    # env-merge semantics in sync with its own risk-node walk, rather
    # than duplicating the branch/merge logic.
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
        # No else — the "nothing happened" path is itself a possible
        # outcome, so merge in the original env too.
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

    # Loop body runs 0-or-more times — approximated as a 2-way merge
    # between "never entered" (current env) and "ran the body once"
    # (env after one pass), which is enough to catch a var whose type
    # changes inside the loop without modeling iteration count.
    private def infer_loop(body : Body, env : Env) : TypeHint
      after_env = env.dup
      infer_body(body, after_env)
      merge_envs_into(env, [env.dup, after_env])
      UnknownType.new
    end

    # Merges a set of branch envs back into `env` in place: any key
    # present in every branch env merges via TypeHint.merge; a key
    # missing from at least one branch is dropped (reverts to
    # UnknownType via ordinary lookup miss) rather than guessed at.
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
