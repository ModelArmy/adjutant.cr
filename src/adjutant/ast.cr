module Adjutant
  # Base class for all AST nodes.
  # Carries source position for error reporting.
  abstract class Node
    getter line : Int32
    getter column : Int32

    def initialize(@line, @column)
    end
  end

  # -------------------------------------------------------------------------
  # Literals
  # -------------------------------------------------------------------------

  class NilLiteral < Node; end

  class BoolLiteral < Node
    # ameba:disable Naming/QueryBoolMethods - Storing, not testing
    getter value : Bool

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class IntLiteral < Node
    getter value : String # raw lexeme; parsed to Int64 at compile time

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class FloatLiteral < Node
    getter value : String # raw lexeme; parsed to Float64 at compile time

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class StringLiteral < Node
    getter value : String

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  # An interpolated string: alternating StringPart/StringEnd and expression nodes.
  class InterpString < Node
    getter parts : Array(Node) # StringFragment | any expression node

    def initialize(@parts, line, column)
      super(line, column)
    end
  end

  # A literal string fragment within an interpolated string.
  class StringFragment < Node
    getter value : String

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class SymbolLiteral < Node
    getter value : String # without leading colon

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class RangeLiteral < Node
    getter start_node : Node
    getter end_node : Node
    getter? exclusive : Bool

    def initialize(@start_node, @end_node, @exclusive, line, column)
      super(line, column)
    end
  end

  class ArrayLiteral < Node
    getter elements : Array(Node)

    def initialize(@elements, line, column)
      super(line, column)
    end
  end

  class HashLiteral < Node
    getter pairs : Array({Node, Node})

    def initialize(@pairs, line, column)
      super(line, column)
    end
  end

  # -------------------------------------------------------------------------
  # Variables and identifiers
  # -------------------------------------------------------------------------

  class Identifier < Node
    getter name : String

    def initialize(@name, line, column)
      super(line, column)
    end
  end

  class Constant < Node
    getter name : String

    def initialize(@name, line, column)
      super(line, column)
    end
  end

  # Marker for a leading `::` — the explicit top-level namespace, e.g.
  # `::A` or `::A::B`. Used only as ConstPath#namespace; never compiled
  # as a value on its own.
  class TopLevel < Node
  end

  # Explicit constant-path access: `A::B`, `A::B::C`, or `::A` (rooted at
  # the top level via TopLevel). `namespace` is the left side (a
  # Constant, nested ConstPath, or TopLevel); `name` is the rightmost
  # segment. Distinct from Constant, which does lexical-scope lookup —
  # ConstPath does a direct lookup in the resolved namespace's own
  # constants table only.
  class ConstPath < Node
    getter namespace : Node
    getter name : String

    def initialize(@namespace, @name, line, column)
      super(line, column)
    end
  end

  class IVar < Node
    getter name : String

    def initialize(@name, line, column)
      super(line, column)
    end
  end

  class CVar < Node
    getter name : String

    def initialize(@name, line, column)
      super(line, column)
    end
  end

  class SelfNode < Node; end

  class MethodName < Node; end # __method__ / __callee__

  # -------------------------------------------------------------------------
  # Operations
  # -------------------------------------------------------------------------

  class Binary < Node
    getter op : TokenKind
    getter left : Node
    getter right : Node

    def initialize(@op, @left, @right, line, column)
      super(line, column)
    end
  end

  class Unary < Node
    getter op : TokenKind
    getter expr : Node

    def initialize(@op, @expr, line, column)
      super(line, column)
    end
  end

  class Ternary < Node
    getter cond : Node
    getter then_branch : Node
    getter else_branch : Node

    def initialize(@cond, @then_branch, @else_branch, line, column)
      super(line, column)
    end
  end

  # -------------------------------------------------------------------------
  # Assignment
  # -------------------------------------------------------------------------

  class Assign < Node
    getter target : Node # Identifier | IVar | CVar | Index
    getter value : Node

    def initialize(@target, @value, line, column)
      super(line, column)
    end
  end

  class MultiAssign < Node
    getter targets : Array(Node)
    getter values : Array(Node)

    def initialize(@targets, @values, line, column)
      super(line, column)
    end
  end

  class OpAssign < Node
    getter op : TokenKind # the base operator e.g. Plus for +=
    getter target : Node
    getter value : Node

    def initialize(@op, @target, @value, line, column)
      super(line, column)
    end
  end

  # ||= and &&=
  class CondAssign < Node
    getter op : TokenKind # OrAssign or AndAssign
    getter target : Node
    getter value : Node

    def initialize(@op, @target, @value, line, column)
      super(line, column)
    end
  end

  # -------------------------------------------------------------------------
  # Calls and indexing
  # -------------------------------------------------------------------------

  # Represents a method call or bare function call.
  # recv is nil for bare calls (puts, require, etc.)
  class Call < Node
    getter receiver : Node?
    getter method : String
    getter args : Array(Node)
    getter block : BlockNode?
    getter? safe : Bool # &. safe navigation

    def initialize(@receiver, @method, @args, @block, @safe, line, column)
      super(line, column)
    end
  end

  class Index < Node
    getter target : Node
    getter index : Node
    getter? safe : Bool

    def initialize(@target, @index, @safe, line, column)
      super(line, column)
    end
  end

  class IndexAssign < Node
    getter target : Node
    getter index : Node
    getter value : Node

    def initialize(@target, @index, @value, line, column)
      super(line, column)
    end
  end

  # -------------------------------------------------------------------------
  # Definitions
  # -------------------------------------------------------------------------

  # Parameter kinds within a def or lambda
  class Param < Node
    getter name : String
    getter default : Node?     # nil → required param
    getter? splat : Bool       # *args
    getter? block_param : Bool # &block
    getter? kwarg : Bool       # name: or name: default

    def initialize(@name, @default, @splat, @block_param, @kwarg, line, column)
      super(line, column)
    end
  end

  class DefNode < Node
    getter name : String
    getter receiver : Node? # for def obj.method
    getter params : Array(Param)
    getter body : Body

    def initialize(@name, @receiver, @params, @body, line, column)
      super(line, column)
    end
  end

  class ClassNode < Node
    getter name : String
    getter superclass : String?
    getter body : Body

    def initialize(@name, @superclass, @body, line, column)
      super(line, column)
    end
  end

  class ModuleNode < Node
    getter name : String
    getter body : Body

    def initialize(@name, @body, line, column)
      super(line, column)
    end
  end

  # A block passed to a call: { |x| ... } or do |x| ... end
  class BlockNode < Node
    getter params : Array(Param)
    getter body : Body

    def initialize(@params, @body, line, column)
      super(line, column)
    end
  end

  class Lambda < Node
    getter params : Array(Param)
    getter body : Body

    def initialize(@params, @body, line, column)
      super(line, column)
    end
  end

  # -------------------------------------------------------------------------
  # Control flow
  # -------------------------------------------------------------------------

  class Body < Node
    getter stmts : Array(Node)

    def initialize(@stmts, line, column)
      super(line, column)
    end
  end

  class IfNode < Node
    getter cond : Node
    getter then_branch : Body
    getter elsif_branches : Array({Node, Body})
    getter else_branch : Body?

    def initialize(@cond, @then_branch, @elsif_branches, @else_branch, line, column)
      super(line, column)
    end
  end

  class UnlessNode < Node
    getter cond : Node
    getter then_branch : Body
    getter else_branch : Body?

    def initialize(@cond, @then_branch, @else_branch, line, column)
      super(line, column)
    end
  end

  class WhileNode < Node
    getter cond : Node
    getter body : Body
    getter? until_loop : Bool # true for `until`

    def initialize(@cond, @body, @until_loop, line, column)
      super(line, column)
    end
  end

  class LoopNode < Node
    getter body : Body

    def initialize(@body, line, column)
      super(line, column)
    end
  end

  class ForNode < Node
    getter vars : Array(String)
    getter iter : Node
    getter body : Body

    def initialize(@vars, @iter, @body, line, column)
      super(line, column)
    end
  end

  class CaseNode < Node
    getter subject : Node?
    getter whens : Array({Array(Node), Body})
    getter else_branch : Body?

    def initialize(@subject, @whens, @else_branch, line, column)
      super(line, column)
    end
  end

  class ReturnNode < Node
    getter value : Node?

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class BreakNode < Node
    getter value : Node?

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class NextNode < Node
    getter value : Node?

    def initialize(@value, line, column)
      super(line, column)
    end
  end

  class RedoNode < Node; end

  class YieldNode < Node
    getter args : Array(Node)

    def initialize(@args, line, column)
      super(line, column)
    end
  end

  class SuperNode < Node
    getter args : Array(Node)
    getter? forwarded : Bool # bare `super` with no parens — forwards all args

    def initialize(@args, @forwarded, line, column)
      super(line, column)
    end
  end

  # -------------------------------------------------------------------------
  # Exception handling
  # -------------------------------------------------------------------------

  class BeginNode < Node
    getter body : Body
    getter rescue_var : String?
    getter rescue_body : Body?
    getter ensure_body : Body?

    def initialize(@body, @rescue_var, @rescue_body, @ensure_body, line, column)
      super(line, column)
    end
  end

  class RetryNode < Node; end

  # -------------------------------------------------------------------------
  # Misc
  # -------------------------------------------------------------------------

  class RequireNode < Node
    getter path : Node

    def initialize(@path, line, column)
      super(line, column)
    end
  end

  class AliasNode < Node
    getter new_name : String
    getter old_name : String

    def initialize(@new_name, @old_name, line, column)
      super(line, column)
    end
  end

  # Modifier forms: `expr if cond`, `expr while cond`, etc.
  class ModifierIf < Node
    getter cond : Node
    getter body : Node
    getter? negated : Bool # true for `unless`

    def initialize(@cond, @body, @negated, line, column)
      super(line, column)
    end
  end

  class ModifierWhile < Node
    getter cond : Node
    getter body : Node
    getter? until_loop : Bool

    def initialize(@cond, @body, @until_loop, line, column)
      super(line, column)
    end
  end
end
