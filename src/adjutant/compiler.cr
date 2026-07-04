require "./ast"
require "./bytecode"

module Adjutant
  class CompileError < Exception
    getter line : Int32
    getter column : Int32

    def initialize(message : String, @line, @column)
      super("#{message} (line #{line}, col #{column})")
    end
  end

  # Compiler state for a single loop scope.
  private struct LoopScope
    property start_pos : Int32     # position of condition check (jump-back target)
    property body_pos : Int32      # position after condition (redo target)
    property breaks : Array(Int32) # indices of Break jumps to patch

    def initialize(@start_pos, @body_pos = 0)
      @breaks = [] of Int32
    end
  end

  # Compiler: walks an AST and emits bytecode into a Chunk.
  #
  # One Compiler instance per scope (script, method, block).
  # Nested scopes (method bodies, blocks) create child Compiler instances
  # that produce independent Chunks, stored as constants in the parent.
  # Tracks local variable names and their frame slot indices for one scope.
  # A scope corresponds to one method body or block body.
  # Blocks carry a parent reference for single-level closure capture.
  class CompilerScope
    getter vars : Hash(String, Int32)
    property next_slot : Int32
    getter? is_block : Bool
    getter parent : CompilerScope?

    def initialize(@is_block = false, @parent = nil)
      @vars = {} of String => Int32
      @next_slot = 0
    end

    # Define a new local variable, returning its slot index.
    def define(name : String) : Int32
      slot = @next_slot
      @vars[name] = slot
      @next_slot += 1
      slot
    end

    # Resolve a name in this scope's own vars.
    def resolve_local(name : String) : Int32?
      @vars[name]?
    end

    # Resolve a name in the parent scope (block closure capture, one level).
    def resolve_outer(name : String) : Int32?
      return nil unless @is_block
      @parent.try(&.vars[name]?)
    end
  end

  class Compiler
    MAX_LOOP_DEPTH =         16
    NO_SUPER       = 0xFFFF_u16

    def initialize(symbols : SymbolTable)
      @symbols = symbols
      @chunk = Chunk.new
      @loop_stack = [] of LoopScope
      @class_depth = 0
      @in_block = false
      @scope = nil.as(CompilerScope?)
    end

    # Compile a full program body and return the resulting Chunk.
    def self.compile(body : Body, symbols : SymbolTable) : Chunk
      c = new(symbols)
      c.compile_body(body)
      c.chunk
    end

    # Compile a method/block body.
    # Returns {chunk, local_count} — local_count is the number of frame
    # slots the body needs (params + locals defined in the body).
    def self.compile_proc(
      body : Body,
      symbols : SymbolTable,
      params : Array(String) = [] of String,
      in_block : Bool = false,
      parent_scope : CompilerScope? = nil,
    ) : {Chunk, Int32}
      c = new(symbols)
      scope = CompilerScope.new(in_block, parent_scope)
      c.scope = scope
      params.each { |param| scope.define(param) }
      c.compile_body(body)
      c.emit_ret(0)
      local_count = scope.next_slot
      c.scope = nil
      {c.chunk, local_count}
    end

    protected getter chunk
    protected getter symbols
    protected property scope : CompilerScope?
    protected setter in_block

    # -----------------------------------------------------------------------

    protected def compile_body(body : Body) : Nil
      if body.stmts.empty?
        emit_nil(body.line)
        return
      end
      body.stmts.each_with_index do |stmt, i|
        compile_node(stmt)
        # Pop intermediate results; keep the last one as the body value
        @chunk.emit(Op::Pop, stmt.line) unless i == body.stmts.size - 1
      end
    end

    protected def emit_ret(line : Int32) : Nil
      @chunk.emit(Op::Ret, line)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    protected def compile_node(node : Node) : Nil
      case node
      when NilLiteral     then emit_nil(node.line)
      when BoolLiteral    then compile_bool(node)
      when IntLiteral     then compile_int(node)
      when FloatLiteral   then compile_float(node)
      when StringLiteral  then compile_string(node)
      when StringFragment then compile_string_fragment(node)
      when InterpString   then compile_interp_string(node)
      when SymbolLiteral  then compile_symbol(node)
      when ArrayLiteral   then compile_array(node)
      when HashLiteral    then compile_hash(node)
      when RangeLiteral   then compile_range(node)
      when Identifier     then compile_identifier(node)
      when Constant       then compile_constant(node)
      when ConstPath      then compile_const_path(node)
      when IVar           then compile_ivar(node)
      when CVar           then compile_cvar(node)
      when SelfNode       then compile_self(node)
      when MethodName     then compile_method_name(node)
      when Binary         then compile_binary(node)
      when Unary          then compile_unary(node)
      when Ternary        then compile_ternary(node)
      when Assign         then compile_assign(node)
      when OpAssign       then compile_op_assign(node)
      when CondAssign     then compile_cond_assign(node)
      when MultiAssign    then compile_multi_assign(node)
      when Call           then compile_call(node)
      when Index          then compile_index(node)
      when IndexAssign    then compile_index_assign(node)
      when DefNode        then compile_def(node)
      when ClassNode      then compile_class(node)
      when ModuleNode     then compile_module(node)
      when Lambda         then compile_lambda(node)
      when Body           then compile_body(node)
      when IfNode         then compile_if(node)
      when UnlessNode     then compile_unless(node)
      when WhileNode      then compile_while(node)
      when LoopNode       then compile_loop(node)
      when ForNode        then compile_for(node)
      when CaseNode       then compile_case(node)
      when ReturnNode     then compile_return(node)
      when BreakNode      then compile_break(node)
      when NextNode       then compile_next(node)
      when RedoNode       then compile_redo(node)
      when YieldNode      then compile_yield(node)
      when SuperNode      then compile_super(node)
      when BeginNode      then compile_begin(node)
      when RetryNode      then compile_retry(node)
      when RequireNode    then compile_require(node)
      when AliasNode      then compile_alias(node)
      when ModifierIf     then compile_modifier_if(node)
      when ModifierWhile  then compile_modifier_while(node)
      else
        raise CompileError.new("unknown node type: #{node.class}", node.line, node.column)
      end
    end

    # --- Literals -----------------------------------------------------------

    private def emit_nil(line : Int32) : Nil
      idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, line, c: idx)
    end

    private def compile_bool(node : BoolLiteral) : Nil
      idx = @chunk.add_const(Value.bool(node.value))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_int(node : IntLiteral) : Nil
      raw = node.value
      n = raw.starts_with?("0x") || raw.starts_with?("0X") ? raw[2..].to_i64(16) : raw.to_i64
      idx = @chunk.add_const(Value.int(n))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_float(node : FloatLiteral) : Nil
      idx = @chunk.add_const(Value.float(node.value.to_f64))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_string(node : StringLiteral) : Nil
      idx = @chunk.add_const(Value.string(node.value))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_string_fragment(node : StringFragment) : Nil
      idx = @chunk.add_const(Value.string(node.value))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_interp_string(node : InterpString) : Nil
      node.parts.each { |part| compile_node(part) }
      @chunk.emit(Op::Concat, node.line, a: node.parts.size.to_u8)
    end

    private def compile_symbol(node : SymbolLiteral) : Nil
      idx = intern(node.value)
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_array(node : ArrayLiteral) : Nil
      node.elements.each { |e| compile_node(e) }
      @chunk.emit(Op::MakeArray, node.line, a: node.elements.size.to_u8)
    end

    private def compile_hash(node : HashLiteral) : Nil
      node.pairs.each do |k, v|
        compile_node(k)
        compile_node(v)
      end
      @chunk.emit(Op::MakeHash, node.line, a: node.pairs.size.to_u8)
    end

    private def compile_range(node : RangeLiteral) : Nil
      compile_node(node.start_node)
      compile_node(node.end_node)
      @chunk.emit(Op::MakeRange, node.line, a: node.exclusive? ? 1_u8 : 0_u8)
    end

    # --- Variables ----------------------------------------------------------

    private def compile_identifier(node : Identifier) : Nil
      name = node.name
      if scope = @scope
        if slot = scope.resolve_local(name)
          @chunk.emit(Op::GetLocal, node.line, c: slot.to_u32)
          return
        end
        if slot = scope.resolve_outer(name)
          @chunk.emit(Op::GetOuter, node.line, c: slot.to_u32)
          return
        end
      end
      sym_idx = intern(name)
      @chunk.emit(Op::GetGlobal, node.line, c: sym_idx)
    end

    private def compile_constant(node : Constant) : Nil
      sym_idx = intern(node.name)
      @chunk.emit(Op::GetConstant, node.line, c: sym_idx)
    end

    private def compile_const_path(node : ConstPath) : Nil
      sym_idx = intern(node.name)
      if node.namespace.is_a?(TopLevel)
        @chunk.emit(Op::GetGlobalConstant, node.line, c: sym_idx)
      else
        compile_node(node.namespace)
        @chunk.emit(Op::GetConstantFrom, node.line, c: sym_idx)
      end
    end

    private def compile_ivar(node : IVar) : Nil
      sym_idx = intern(node.name)
      @chunk.emit(Op::GetIvar, node.line, c: sym_idx)
    end

    private def compile_cvar(node : CVar) : Nil
      sym_idx = intern(node.name)
      @chunk.emit(Op::GetCvar, node.line, c: sym_idx)
    end

    private def compile_self(node : SelfNode) : Nil
      @chunk.emit(Op::GetClass, node.line)
    end

    private def compile_method_name(node : MethodName) : Nil
      @chunk.emit(Op::GetMethodName, node.line)
    end

    # --- Binary expressions -------------------------------------------------

    private def compile_binary(node : Binary) : Nil
      case node.op
      when TokenKind::OrOr, TokenKind::KwOr
        compile_short_circuit_or(node)
      when TokenKind::AndAnd, TokenKind::KwAnd
        compile_short_circuit_and(node)
      when TokenKind::Spaceship
        compile_spaceship(node)
      when TokenKind::NEq
        compile_node(node.left)
        compile_node(node.right)
        @chunk.emit(Op::Eq, node.line)
        @chunk.emit(Op::Not, node.line)
      else
        compile_node(node.left)
        compile_node(node.right)
        @chunk.emit(binary_op(node.op), node.line)
      end
    end

    private def compile_short_circuit_or(node : Binary) : Nil
      compile_node(node.left)
      @chunk.emit(Op::Dup, node.line)
      jmp_true = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      jmp_end = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(jmp_true, @chunk.pos)
      @chunk.emit(Op::Pop, node.line)
      compile_node(node.right)
      @chunk.patch_jump(jmp_end, @chunk.pos)
    end

    private def compile_short_circuit_and(node : Binary) : Nil
      compile_node(node.left)
      @chunk.emit(Op::Dup, node.line)
      jmp_false = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      @chunk.emit(Op::Pop, node.line)
      compile_node(node.right)
      jmp_end = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(jmp_false, @chunk.pos)
      @chunk.patch_jump(jmp_end, @chunk.pos)
    end

    private def compile_spaceship(node : Binary) : Nil
      compile_node(node.left)
      compile_node(node.right)
      sym_idx = intern("<=>")
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      @chunk.emit(Op::Call, node.line, a: 2_u8, c: sym_idx)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def binary_op(op : TokenKind) : Op
      case op
      when TokenKind::Plus    then Op::Add
      when TokenKind::Minus   then Op::Sub
      when TokenKind::Star    then Op::Mul
      when TokenKind::Slash   then Op::Div
      when TokenKind::Percent then Op::Mod
      when TokenKind::Amp     then Op::BitAnd
      when TokenKind::Pipe    then Op::BitOr
      when TokenKind::Shl     then Op::Shl
      when TokenKind::Shr     then Op::Shr
      when TokenKind::Caret   then Op::Xor
      when TokenKind::EqEq    then Op::Eq
      when TokenKind::Lt      then Op::Lt
      when TokenKind::LtE     then Op::Lte
      when TokenKind::Gt      then Op::Gt
      when TokenKind::GtE     then Op::Gte
      else
        raise "unknown binary op: #{op}"
      end
    end

    # --- Unary --------------------------------------------------------------

    private def compile_unary(node : Unary) : Nil
      compile_node(node.expr)
      case node.op
      when TokenKind::Bang  then @chunk.emit(Op::Not, node.line)
      when TokenKind::Minus then @chunk.emit(Op::Neg, node.line)
      when TokenKind::Tilde then @chunk.emit(Op::BitNot, node.line)
      end
    end

    # --- Ternary ------------------------------------------------------------

    private def compile_ternary(node : Ternary) : Nil
      compile_node(node.cond)
      jmp_false = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      compile_node(node.then_branch)
      jmp_end = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(jmp_false, @chunk.pos)
      compile_node(node.else_branch)
      @chunk.patch_jump(jmp_end, @chunk.pos)
    end

    # --- Assignment ---------------------------------------------------------

    private def compile_assign(node : Assign) : Nil
      compile_node(node.value)
      emit_store(node.target, node.line)
    end

    private def compile_op_assign(node : OpAssign) : Nil
      # x += y  →  x = x + y
      compile_node(node.target)
      compile_node(node.value)
      @chunk.emit(binary_op(node.op), node.line)
      emit_store(node.target, node.line)
    end

    private def compile_cond_assign(node : CondAssign) : Nil
      # x ||= y — only assign if x is falsy
      # x &&= y — only assign if x is truthy
      compile_node(node.target)
      @chunk.emit(Op::Dup, node.line)
      if node.op == TokenKind::OrAssign
        jmp = @chunk.emit_jump(Op::JumpIfFalse, node.line)
        jmp_end = @chunk.emit_jump(Op::Jump, node.line)
        @chunk.patch_jump(jmp, @chunk.pos)
        @chunk.emit(Op::Pop, node.line)
        compile_node(node.value)
        emit_store(node.target, node.line)
        @chunk.patch_jump(jmp_end, @chunk.pos)
      else # AndAssign
        jmp = @chunk.emit_jump(Op::JumpIfTrue, node.line)
        jmp_end = @chunk.emit_jump(Op::Jump, node.line)
        @chunk.patch_jump(jmp, @chunk.pos)
        @chunk.emit(Op::Pop, node.line)
        compile_node(node.value)
        emit_store(node.target, node.line)
        @chunk.patch_jump(jmp_end, @chunk.pos)
      end
    end

    private def compile_multi_assign(node : MultiAssign) : Nil
      node.values.each { |v| compile_node(v) }
      tc = node.targets.size.to_u8
      vc = node.values.size.to_u8
      @chunk.emit(Op::MultiUnpack, node.line, a: tc, b: vc.to_u16)
      node.targets.reverse_each do |target|
        emit_store(target, node.line)
        @chunk.emit(Op::Pop, node.line)
      end
      emit_nil(node.line)
    end

    # Store the top-of-stack value into the appropriate variable slot.
    # Inside a method/block scope, bare identifiers are locals.
    # At the top level (no scope), they are globals.
    # Constants are lexically scoped — see SetConstant.
    private def emit_store(target : Node, line : Int32) : Nil
      case target
      when Identifier
        name = target.name
        if scope = @scope
          if slot = scope.resolve_local(name)
            @chunk.emit(Op::SetLocal, line, c: slot.to_u32)
            return
          end
          if slot = scope.resolve_outer(name)
            @chunk.emit(Op::SetOuter, line, c: slot.to_u32)
            return
          end
          # In a block, an unresolved name falls through to global —
          # blocks don't introduce new locals for names they can't see.
          # In a method body, first assignment defines a new local.
          unless scope.is_block?
            slot = scope.define(name)
            @chunk.emit(Op::SetLocal, line, c: slot.to_u32)
            return
          end
        end
        sym_idx = intern(name)
        @chunk.emit(Op::SetGlobal, line, c: sym_idx)
        return
      when Constant
        sym_idx = intern(target.name)
        @chunk.emit(Op::SetConstant, line, c: sym_idx)
        return
      when IVar
        sym_idx = intern(target.name)
        @chunk.emit(Op::SetIvar, line, c: sym_idx)
      when CVar
        sym_idx = intern(target.name)
        @chunk.emit(Op::SetCvar, line, c: sym_idx)
      when Index
        compile_node(target.target)
        compile_node(target.index)
        @chunk.emit(Op::SetIndex, line)
      else
        raise CompileError.new("invalid assignment target: #{target.class}", line, 0)
      end
    end

    # --- Calls --------------------------------------------------------------

    private def compile_call(node : Call) : Nil
      if recv = node.receiver
        compile_node(recv)
      end
      node.args.each { |arg| compile_node(arg) }
      # Register block if present — MakeProc pushes it, SetBlock pops it
      if blk = node.block
        blk_params = blk.params.map(&.name)
        blk_chunk, blk_locals = Compiler.compile_proc(
          blk.body, @symbols,
          params: blk_params,
          in_block: true,
          parent_scope: @scope
        )
        sproc = ScriptProc.new(blk_chunk, "<block>", blk_params, blk_locals, true)
        proc_idx = @chunk.add_const(Value.proc(sproc))
        @chunk.emit(Op::MakeProc, node.line, c: proc_idx)
      else
        nil_idx = @chunk.add_const(Value.nil_value)
        @chunk.emit(Op::Const, node.line, c: nil_idx)
      end
      @chunk.emit(Op::SetBlock, node.line)
      sym_idx = intern(node.method)
      safe_bit = node.safe? ? 0b01_u16 : 0_u16
      recv_bit = node.receiver ? 0b10_u16 : 0_u16
      recv = node.receiver ? 1_u8 : 0_u8
      argc = (node.args.size + recv).to_u8
      op = node.safe? ? Op::SafeCall : Op::Call
      @chunk.emit(op, node.line, a: argc, b: safe_bit | recv_bit, c: sym_idx)
    end

    private def compile_index(node : Index) : Nil
      compile_node(node.target)
      compile_node(node.index)
      op = node.safe? ? Op::SafeIndex : Op::GetIndex
      @chunk.emit(op, node.line)
    end

    private def compile_index_assign(node : IndexAssign) : Nil
      compile_node(node.target)
      compile_node(node.index)
      compile_node(node.value)
      @chunk.emit(Op::SetIndex, node.line)
    end

    # --- Definitions --------------------------------------------------------

    private def compile_def(node : DefNode) : Nil
      params = node.params.map(&.name)
      body_chunk, local_count = Compiler.compile_proc(
        node.body, @symbols,
        params: params,
        in_block: false
      )
      sproc = ScriptProc.new(body_chunk, node.name, params, local_count, false)
      proc_idx = @chunk.add_const(Value.proc(sproc))
      @chunk.emit(Op::MakeProc, node.line, c: proc_idx)
      sym_idx = intern(node.name)
      if recv = node.receiver
        compile_node(recv)
        @chunk.emit(Op::DefSingleton, node.line, c: sym_idx)
      elsif @class_depth > 0
        @chunk.emit(Op::DefMethod, node.line, c: sym_idx)
      else
        @chunk.emit(Op::SetGlobal, node.line, c: sym_idx)
      end
    end

    private def compile_class(node : ClassNode) : Nil
      name_idx = intern(node.name)
      super_idx = if s = node.superclass
                    intern(s).to_u16
                  else
                    NO_SUPER
                  end

      @chunk.emit(Op::GetClass, node.line)                             # [old_self]
      @chunk.emit(Op::MakeClass, node.line, b: super_idx, c: name_idx) # [old_self, new_class]
      @chunk.emit(Op::SetConstant, node.line, c: name_idx)             # [old_self, new_class]  registers in old_self's scope (or globals at top level)
      @chunk.emit(Op::SetClass, node.line)                             # [old_self]  self := new_class
      @class_depth += 1
      compile_body(node.body) # [old_self, body_val]
      @class_depth -= 1
      @chunk.emit(Op::Pop, node.line)      # [old_self]  discard body value
      @chunk.emit(Op::SetClass, node.line) # []  self := old_self (restored)
      emit_nil(node.line)                  # [nil]  class-def statement's own value
    end

    private def compile_module(node : ModuleNode) : Nil
      name_idx = intern(node.name)

      @chunk.emit(Op::GetClass, node.line)                 # [old_self]
      @chunk.emit(Op::MakeModule, node.line, c: name_idx)  # [old_self, new_module]
      @chunk.emit(Op::SetConstant, node.line, c: name_idx) # [old_self, new_module]
      @chunk.emit(Op::SetClass, node.line)                 # [old_self]  self := new_module
      @class_depth += 1
      compile_body(node.body) # [old_self, body_val]
      @class_depth -= 1
      @chunk.emit(Op::Pop, node.line)      # [old_self]
      @chunk.emit(Op::SetClass, node.line) # []  self := old_self (restored)
      emit_nil(node.line)                  # [nil]
    end

    private def compile_lambda(node : Lambda) : Nil
      params = node.params.map(&.name)
      lam_chunk, local_count = Compiler.compile_proc(
        node.body, @symbols,
        params: params,
        in_block: true,
        parent_scope: @scope
      )
      sproc = ScriptProc.new(lam_chunk, "<lambda>", params, local_count, true)
      proc_idx = @chunk.add_const(Value.proc(sproc))
      @chunk.emit(Op::MakeProc, node.line, c: proc_idx)
    end

    # --- Control flow -------------------------------------------------------

    private def compile_if(node : IfNode) : Nil
      compile_node(node.cond)
      jmp_false = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      compile_body(node.then_branch)
      patches = [jmp_false] of Int32

      node.elsif_branches.each do |elsif_cond, elsif_body|
        jmp_end = @chunk.emit_jump(Op::Jump, node.line)
        patches << jmp_end
        @chunk.patch_jump(patches.shift, @chunk.pos)
        compile_node(elsif_cond)
        jmp_f = @chunk.emit_jump(Op::JumpIfFalse, node.line)
        compile_body(elsif_body)
        patches.unshift(jmp_f)
      end

      jmp_end = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(patches.first, @chunk.pos)
      if else_b = node.else_branch
        compile_body(else_b)
      else
        emit_nil(node.line)
      end
      @chunk.patch_jump(jmp_end, @chunk.pos)
    end

    private def compile_unless(node : UnlessNode) : Nil
      compile_node(node.cond)
      jmp_true = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      jmp_body = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(jmp_true, @chunk.pos)
      compile_body(node.then_branch)
      jmp_end = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(jmp_body, @chunk.pos)
      if else_b = node.else_branch
        compile_body(else_b)
      else
        emit_nil(node.line)
      end
      @chunk.patch_jump(jmp_end, @chunk.pos)
    end

    private def compile_while(node : WhileNode) : Nil
      raise CompileError.new("loop nesting too deep", node.line, node.column) if @loop_stack.size >= MAX_LOOP_DEPTH
      loop_start = @chunk.pos
      scope = LoopScope.new(loop_start)
      @loop_stack.push(scope)

      compile_node(node.cond)
      # For `until`, invert the condition
      @chunk.emit(Op::Not, node.line) if node.until_loop?
      jmp_exit = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      scope.body_pos = @chunk.pos

      compile_body(node.body)
      @chunk.emit(Op::Pop, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)
      @chunk.patch_jump(jmp_exit, @chunk.pos)

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, @chunk.pos) }
      emit_nil(node.line)
    end

    private def compile_loop(node : LoopNode) : Nil
      raise CompileError.new("loop nesting too deep", node.line, node.column) if @loop_stack.size >= MAX_LOOP_DEPTH
      loop_start = @chunk.pos
      scope = LoopScope.new(loop_start)
      scope.body_pos = loop_start
      @loop_stack.push(scope)

      compile_body(node.body)
      @chunk.emit(Op::Pop, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, @chunk.pos) }
      emit_nil(node.line)
    end

    private def compile_for(node : ForNode) : Nil
      # Desugar: `for i in expr do body end`
      # → `expr.each { |i| body }`
      compile_node(node.iter)
      # Build a synthetic block
      sym_idx = intern("each")
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      @chunk.emit(Op::Call, node.line, a: 1_u8, c: sym_idx)
    end

    private def compile_case(node : CaseNode) : Nil
      end_patches = [] of Int32

      if subject = node.subject
        compile_node(subject)
      end

      node.whens.each do |patterns, when_body|
        pattern_patches = [] of Int32
        patterns.each_with_index do |pat, _i|
          if node.subject
            @chunk.emit(Op::Dup, node.line)
            compile_node(pat)
            sym_idx = intern("===")
            nil_idx = @chunk.add_const(Value.nil_value)
            @chunk.emit(Op::Const, node.line, c: nil_idx)
            @chunk.emit(Op::SetBlock, node.line)
            @chunk.emit(Op::Call, node.line, a: 2_u8, c: sym_idx)
          else
            compile_node(pat)
          end
          pattern_patches << @chunk.emit_jump(Op::JumpIfTrue, node.line)
        end
        jmp_skip = @chunk.emit_jump(Op::Jump, node.line)
        pattern_patches.each { |patch| @chunk.patch_jump(patch, @chunk.pos) }
        @chunk.emit(Op::Pop, node.line) if node.subject # pop subject dup
        compile_body(when_body)
        end_patches << @chunk.emit_jump(Op::Jump, node.line)
        @chunk.patch_jump(jmp_skip, @chunk.pos)
      end

      @chunk.emit(Op::Pop, node.line) if node.subject # pop remaining subject
      if else_b = node.else_branch
        compile_body(else_b)
      else
        emit_nil(node.line)
      end
      end_patches.each { |patch| @chunk.patch_jump(patch, @chunk.pos) }
    end

    private def compile_return(node : ReturnNode) : Nil
      if v = node.value
        compile_node(v)
      else
        emit_nil(node.line)
      end
      @chunk.emit(Op::Ret, node.line)
    end

    private def compile_break(node : BreakNode) : Nil
      if v = node.value
        compile_node(v)
      else
        emit_nil(node.line)
      end
      if !@loop_stack.empty?
        jmp = @chunk.emit_jump(Op::Jump, node.line)
        @loop_stack.last.breaks << jmp
      else
        @chunk.emit(Op::BlockBreak, node.line)
      end
    end

    private def compile_next(node : NextNode) : Nil
      if !@loop_stack.empty?
        if v = node.value
          compile_node(v)
          @chunk.emit(Op::Pop, node.line)
        end
        @chunk.emit(Op::Jump, node.line, c: @loop_stack.last.start_pos.to_u32)
      else
        if v = node.value
          compile_node(v)
        else
          emit_nil(node.line)
        end
        @chunk.emit(Op::Ret, node.line)
      end
    end

    private def compile_redo(node : RedoNode) : Nil
      raise CompileError.new("redo outside loop", node.line, node.column) if @loop_stack.empty?
      @chunk.emit(Op::Jump, node.line, c: @loop_stack.last.body_pos.to_u32)
    end

    private def compile_yield(node : YieldNode) : Nil
      node.args.each { |arg| compile_node(arg) }
      @chunk.emit(Op::Yield, node.line, a: node.args.size.to_u8)
    end

    private def compile_super(node : SuperNode) : Nil
      node.args.each { |arg| compile_node(arg) }
      sym_idx = intern("super")
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      @chunk.emit(Op::Call, node.line, a: node.args.size.to_u8, c: sym_idx)
    end

    # --- Exception handling -------------------------------------------------

    private def compile_begin(node : BeginNode) : Nil
      if node.rescue_body.nil? && node.ensure_body.nil?
        compile_body(node.body)
        return
      end

      # Op::Try's jump target only ever gets patched inside
      # compile_rescue_clause. An ensure-only begin (no rescue) has no
      # such patch site, so emitting Try here would push an unpatched
      # NO_TARGET sentinel onto Frame#rescue_handlers — reading it via
      # UInt32#to_i is a checked conversion that raises OverflowError
      # the moment Try executes, since NO_TARGET doesn't fit in Int32.
      # An ensure-only block doesn't catch anything
      # anyway, so it has no need for Try/EndTry at all.
      has_rescue = !node.rescue_body.nil?
      try_at = @chunk.emit_jump(Op::Try, node.line) if has_rescue
      ensure_at = if node.ensure_body
                    @chunk.emit_jump(Op::SetEnsure, node.line)
                  end

      compile_body(node.body)
      @chunk.emit(Op::EndTry, node.line) if has_rescue

      if (rescue_body = node.rescue_body) && (try_pos = try_at)
        compile_rescue_clause(node, rescue_body, try_pos)
      end

      if ensure_body = node.ensure_body
        if ea = ensure_at
          @chunk.patch_jump(ea, @chunk.pos)
        end
        @chunk.emit(Op::EnterEnsure, node.line)
        compile_body(ensure_body)
        # Discard the ensure block's own trailing value — the overall
        # begin/ensure expression's value is the body's (or rescue's),
        # not the ensure block's. compile_body always leaves exactly
        # one value on the stack, so this Pop is always safe.
        @chunk.emit(Op::Pop, node.line)
      end
    end

    private def compile_rescue_clause(node : BeginNode, rescue_body : Body, try_at : Int32) : Nil
      jmp_past_rescue = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(try_at, @chunk.pos)

      # Ruby's bare `rescue` (no explicit class) only catches
      # StandardError and below — fatal Exception-only errors still
      # propagate. Defaulting here reuses the exact same is_a? check
      # as an explicit filter, rather than duplicating an unfiltered
      # "catch everything" path.
      rcls = node.rescue_class || Constant.new("StandardError", node.line, node.column)

      @chunk.emit(Op::PushError, node.line)
      compile_node(rcls)
      # Call is_a?(error, rescue_class) using the same calling
      # convention as `error.is_a?(rescue_class)`.
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      is_a_sym = intern("is_a?")
      @chunk.emit(Op::Call, node.line, a: 2_u8, b: 0b10_u16, c: is_a_sym)
      no_match_jump = @chunk.emit_jump(Op::JumpIfFalse, node.line)

      compile_rescue_bind_and_body(node, rescue_body)
      match_done_jump = @chunk.emit_jump(Op::Jump, node.line)

      @chunk.patch_jump(no_match_jump, @chunk.pos)
      # Class didn't match — keep the error's original identity
      # (class, message) alive as it propagates further out,
      # rather than rebuilding a generic one via Op::Throw.
      @chunk.emit(Op::PushError, node.line)
      @chunk.emit(Op::Reraise, node.line)

      @chunk.patch_jump(match_done_jump, @chunk.pos)
      @chunk.patch_jump(jmp_past_rescue, @chunk.pos)
    end

    private def compile_rescue_bind_and_body(node : BeginNode, rescue_body : Body) : Nil
      if rvar = node.rescue_var
        @chunk.emit(Op::PushError, node.line)
        sym_idx = intern(rvar)
        @chunk.emit(Op::SetGlobal, node.line, c: sym_idx)
        @chunk.emit(Op::Pop, node.line)
      end
      compile_body(rescue_body)
    end

    private def compile_retry(node : RetryNode) : Nil
      @chunk.emit(Op::Retry, node.line)
    end

    # --- Misc ---------------------------------------------------------------

    private def compile_require(node : RequireNode) : Nil
      compile_node(node.path)
      sym_idx = intern("require")
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      @chunk.emit(Op::Call, node.line, a: 1_u8, c: sym_idx)
    end

    private def compile_alias(node : AliasNode) : Nil
      # alias is handled as a runtime call: __alias__(new_name, old_name)
      new_idx = intern(node.new_name)
      old_idx = intern(node.old_name)
      @chunk.emit(Op::Const, node.line, c: new_idx)
      @chunk.emit(Op::Const, node.line, c: old_idx)
      sym_idx = intern("__alias__")
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      @chunk.emit(Op::Call, node.line, a: 2_u8, c: sym_idx)
    end

    private def compile_modifier_if(node : ModifierIf) : Nil
      compile_node(node.cond)
      @chunk.emit(Op::Not, node.line) if node.negated?
      jmp_skip = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      compile_node(node.body)
      jmp_end = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(jmp_skip, @chunk.pos)
      emit_nil(node.line)
      @chunk.patch_jump(jmp_end, @chunk.pos)
    end

    private def compile_modifier_while(node : ModifierWhile) : Nil
      raise CompileError.new("loop nesting too deep", node.line, node.column) if @loop_stack.size >= MAX_LOOP_DEPTH
      loop_start = @chunk.pos
      scope = LoopScope.new(loop_start)
      scope.body_pos = loop_start
      @loop_stack.push(scope)

      compile_node(node.body)
      compile_node(node.cond)
      @chunk.emit(Op::Not, node.line) if node.until_loop?
      jmp_exit = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)
      @chunk.patch_jump(jmp_exit, @chunk.pos)

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, @chunk.pos) }
      emit_nil(node.line)
    end

    # --- Helpers ------------------------------------------------------------

    private def intern(name : String) : UInt32
      sym = @symbols.intern(name)
      @chunk.add_const(Value.symbol(sym))
    end
  end
end
