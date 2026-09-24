module Adjutant
  # The complete bytecode instruction set.
  #
  # Instruction encoding follows Luby's layout:
  #   op  : Op      — the operation
  #   a   : UInt8   — small immediate (argc, element count, flags)
  #   b   : UInt16  — medium immediate (superclass index, etc.)
  #   c   : UInt32  — large immediate (constant pool index, jump target)
  enum Op
    Noop

    # Stack / constants
    Const # push constants[c]
    Pop   # discard top of stack
    Dup   # duplicate top of stack

    # Variables
    GetGlobal # push globals[constants[c].as_sym.name]
    SetGlobal # pop → globals[constants[c].as_sym.name]
    GetIvar   # push self.ivars[constants[c].as_sym.name]
    SetIvar   # pop → self.ivars[constants[c].as_sym.name]
    GetCvar   # push class.cvars[constants[c].as_sym.name]
    SetCvar   # pop → class.cvars[constants[c].as_sym.name]

    # Constants — lexically scoped, distinct from plain globals.
    GetConstant       # push constants[c].as_sym.name, walking the lexical scope chain, then globals; raises if not found
    SetConstant       # pop → set in the innermost lexical scope (self if a class/module, else lexical_scope, else globals)
    GetConstantFrom   # pop a class/module → push its OWN constants[c].as_sym.name (no chain walk); raises if not a class or not found
    GetGlobalConstant # push globals[constants[c].as_sym.name] directly, no lexical walk — leading `::X`; raises if not found

    # Indexing
    GetIndex          # pop index, pop target → push target[index]
    SafeIndex         # like GetIndex but nil-safe
    SetIndex          # pop value, pop index, pop target → target[index] = value
    SetIndexFromValue # pop index, pop target, pop value → target[index] = value (OpAssign/CondAssign/MultiAssign's Index-target path; see emit_store's own comment for why this needs a different pop order from SetIndex)
    SetAttr           # pop value, pop receiver → receiver.name=(value) (real method call); push value

    # Calls
    SetBlock # register block proc from constants[c] before a call

    # Stages keyword arguments for the next Call: pops a (name symbol,
    # value) pairs, pushed alternately as for MakeHash. Emitted only
    # before a call that passes keywords; Call clears the staged pairs.
    SetKwargNames

    # Pushes whether the current call passed the keyword named
    # constants[c]. Emitted only by the default-parameter prologue,
    # since a nil slot can't tell "omitted" from "passed nil".
    HasKwarg

    Call     # call method constants[c], argc=a, b bit0=safe(&.), bit1=has_receiver
    SafeCall # &. nil-safe call

    # Calls the current method's name on the next class or module
    # after the method's lexical scope in the receiver's ancestors;
    # self is unchanged. b bit0 = zsuper (bare `super`): a is 0 and the
    # method's current parameter values are forwarded. Otherwise a
    # arguments are popped as for Call.
    Super

    Ret # return top of stack from current frame

    # Classes and methods
    GetClass     # push current frame's self
    SetClass     # pop → set current frame's self
    MakeClass    # make class: name=constants[c], super=constants[b] (0xFFFF=none)
    MakeModule   # make module: name=constants[c]
    DefMethod    # define method on self (must be a class/module): proc on stack, name=constants[c]
    DefSingleton # define singleton method: proc on stack, recv on stack, name=constants[c]

    # Control flow
    Jump        # unconditional jump to c
    JumpIfFalse # pop, jump to c if falsy
    JumpIfTrue  # pop, jump to c if truthy (for ||=, &&=)

    # Exception handling
    Try         # set rescue handler at c
    EndTry      # clear rescue handler
    Throw       # raise: pop value and throw
    PushError   # push current rescue exception onto stack
    SetEnsure   # register ensure block at c
    EnterEnsure # enter ensure block

    # Ends an ensure body: re-raises the pending error if the ensure
    # was entered by unwinding, else does nothing.
    EndEnsure

    # Pops an error and re-raises it unchanged, keeping its class.
    # Used when no `rescue` clause matches.
    Reraise

    # Collections
    MakeArray # pop a elements → push Array
    MakeHash  # pop a*2 elements (alternating k,v) → push Hash
    MakeRange # pop end, pop start → push Range; a=1 for exclusive
    MakeRegex # pop pattern String (already Concat'd if interpolated) → push Regexp; a=flag bitmask (Builtins::IGNORECASE|EXTENDED|MULTILINE)

    # Arithmetic
    Add
    Sub
    Mul
    Div
    Mod

    # Bitwise / other binary
    BitAnd
    BitOr
    Shl
    Shr
    Xor

    # Unary
    Not
    Neg
    Pos
    BitNot

    # Comparison
    Eq
    TripleEq # `a === b`; also compile_case's per-`when`-pattern check — see this op's own VM handler for the Class/Range/Regexp/Proc special-casing
    Lt
    Lte
    Gt
    Gte

    # String
    Concat # pop a strings → push concatenated string

    # Blocks / iterators
    Yield      # yield to block with a args
    BlockBreak # break from a block iterator (value on stack)

    # Multi-assign
    MultiUnpack # a=target_count, b=value_count — normalise RHS on stack; splats a single Array value when b=1 and a>1

    # Misc
    GetMethodName # push current method name as symbol

    # Local variables (per-frame slots)
    GetLocal # push frame.locals[c]
    SetLocal # pop → frame.locals[c]; push value

    # Pushes the number of positional arguments the current call
    # passed. Emitted only by the default-parameter prologue, since a
    # nil slot can't tell "omitted" from "passed nil".
    GetArgc

    # Closure access to an enclosing scope's locals: a = depth (0 is
    # the nearest enclosing scope), c = slot at that depth.
    GetOuter # push frame.outer_locals[a][c]
    SetOuter # pop → frame.outer_locals[a][c]; push value

    # Proc construction
    MakeProc # push consts[c] (a ScriptProc Value); a=1: wrap as real Proc RubyObject (lambda literals only — see builtins/proc.cr); a=0 (default): push the bare ScriptProc Value as-is (def bodies, call-site block literals)
  end

  # A single encoded instruction.
  struct Instruction
    getter op : Op
    getter a : UInt8  # small immediate
    getter b : UInt16 # medium immediate
    getter c : UInt32 # large immediate / jump target / const index
    getter line : Int32

    def initialize(@op, @line, @a = 0_u8, @b = 0_u16, @c = 0_u32)
    end

    def to_s(io : IO) : Nil
      io << op.to_s.ljust(16)
      io << " a=#{a}" unless a == 0
      io << " b=#{b}" unless b == 0
      io << " c=#{c}" unless c == 0
      io << " (line #{line})"
    end
  end

  # A compiled unit of bytecode — instructions + constant pool + line info.
  #
  # Each Chunk corresponds to one scope: a script, method body, or block.
  class Chunk
    getter code : Array(Instruction)
    getter consts : Array(Value)

    NO_TARGET = 0xFFFF_FFFF_u32

    def initialize
      @code = [] of Instruction
      @consts = [] of Value
    end

    # Emit an instruction, returning its index.
    def emit(op : Op, line : Int32, a : UInt8 = 0_u8, b : UInt16 = 0_u16, c : UInt32 = 0_u32) : Int32
      @code << Instruction.new(op, line, a, b, c)
      @code.size - 1
    end

    # Emit a jump instruction with a placeholder target; return its index for patching.
    def emit_jump(op : Op, line : Int32) : Int32
      emit(op, line, c: NO_TARGET)
    end

    # Patch a previously emitted jump to point to the given target offset.
    def patch_jump(at : Int32, target : Int32) : Nil
      old = @code[at]
      @code[at] = Instruction.new(old.op, old.line, old.a, old.b, target.to_u32)
    end

    # Add a constant to the pool, returning its index.
    # Deduplicates nil, bool, and symbol constants.
    def add_const(value : Value) : UInt32
      if value.null? || value.bool? || value.symbol?
        existing = @consts.index { |v| values_equal?(v, value) }
        return existing.to_u32 if existing
      end
      @consts << value
      (@consts.size - 1).to_u32
    end

    # Current instruction count — useful as a jump target.
    def pos : Int32
      @code.size
    end

    def disassemble(io : IO = STDOUT) : Nil
      @code.each_with_index do |inst, i|
        io << i.to_s.rjust(4) << "  " << inst << "\n"
      end
    end

    private def values_equal?(a : Value, b : Value) : Bool
      return true if a.null? && b.null?
      return a.as_bool == b.as_bool if a.bool? && b.bool?
      # Sym comparison uses integer ID — O(1)
      return a.as_sym == b.as_sym if a.symbol? && b.symbol?
      false
    end
  end
end
