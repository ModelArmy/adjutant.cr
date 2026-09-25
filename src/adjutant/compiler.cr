require "./ast"
require "./bytecode"
require "./diagnostic"
require "./builtins/regexp"

module Adjutant
  class CompileError < Exception
    getter line : Int32
    getter column : Int32

    # The structured diagnostic; nil only for an error built from a
    # plain message.
    getter diagnostic : Diagnostic?

    def initialize(message : String, @line, @column)
      @diagnostic = nil
      super("#{message} (line #{line}, col #{column})")
    end

    # `message` is a one-line summary; render `diagnostic` with
    # `DiagnosticRenderer` for the source snippet.
    def initialize(diagnostic : Diagnostic)
      @diagnostic = diagnostic
      # These raise sites always carry a span; the fallbacks exist
      # because `primary` is nilable for the H series, which never
      # reaches either of these classes.
      @line = diagnostic.primary.try(&.line) || 0
      @column = diagnostic.primary.try(&.column) || 0
      super(diagnostic.to_line)
    end
  end

  # Compiler state for a single loop scope.
  private struct LoopScope
    property start_pos : Int32     # position of condition check (jump-back target)
    property body_pos : Int32      # position after condition (redo target)
    property breaks : Array(Int32) # indices of Break jumps to patch

    # `@ensure_stack.size` when the loop was entered. A `break` or
    # `next` must unwind every begin region opened since then.
    property ensure_depth_at_entry : Int32

    def initialize(@start_pos, @body_pos = 0, @ensure_depth_at_entry = 0)
      @breaks = [] of Int32
    end
  end

  # A begin/rescue/ensure construct the compiler is inside, so a
  # `break` or `next` knows which regions it leaves. Separate from
  # LoopScope because the two nest independently. `ensure_body` is nil
  # for a rescue-only construct, which must still have its handler
  # popped: the jump emits `EnterEnsure` with nothing to run.
  private struct EnsureRegion
    property ensure_body : Body?

    def initialize(@ensure_body)
    end
  end

  # The local variables of one scope (a method, block or top-level
  # body) and their frame slots. A block's `parent` is the scope it
  # closes over.
  class CompilerScope
    getter vars : Hash(String, Int32)
    property next_slot : Int32
    getter? is_block : Bool
    getter parent : CompilerScope?

    # `starting_slot` continues slot numbering from an enclosing scope
    # without seeing its names. A class or module body runs in its
    # enclosing frame, so its locals need fresh slots, but it must not
    # close over the enclosing locals (Ruby raises NameError), so it
    # gets no `parent`.
    def initialize(@is_block = false, @parent = nil, starting_slot : Int32 = 0)
      @vars = {} of String => Int32
      @next_slot = starting_slot
    end

    # Defines a local and returns its slot.
    def define(name : String) : Int32
      slot = @next_slot
      @vars[name] = slot
      @next_slot += 1
      slot
    end

    # This scope's slot for `name`, or nil.
    def resolve_local(name : String) : Int32?
      @vars[name]?
    end

    # Finds `name` in an enclosing scope, for closure capture at any
    # depth. Returns `{depth, slot}`: depth 0 is the immediate parent,
    # matching the order of `Frame#outer_locals` at runtime; `slot` is
    # the index within that level. A `def` has no parent, so the
    # search stops there.
    def resolve_outer(name : String) : {Int32, Int32}?
      return unless @is_block
      depth = 0
      scope = @parent
      while scope
        if slot = scope.vars[name]?
          return {depth, slot}
        end
        scope = scope.parent
        depth += 1
      end
      nil
    end
  end

  class Compiler
    MAX_LOOP_DEPTH =         16
    NO_SUPER       = 0xFFFF_u16

    def initialize(symbols : SymbolTable, def_depth : Int32 = 0)
      @symbols = symbols
      @chunk = Chunk.new
      @loop_stack = [] of LoopScope
      @ensure_stack = [] of EnsureRegion
      @in_block = false
      @scope = nil.as(CompilerScope?)
      @def_depth = def_depth
    end

    # Compiles a top-level program. Returns the chunk and the number of
    # local slots it needs. Its first assignment to a new name defines a
    # local, as in a method body.
    def self.compile(body : Body, symbols : SymbolTable) : {Chunk, Int32}
      c = new(symbols)
      scope = CompilerScope.new(is_block: false, parent: nil)
      c.scope = scope
      c.compile_body(body)
      {c.chunk, scope.next_slot}
    end

    # Compiles a method, lambda or block body. Returns the chunk and
    # the number of frame slots it needs (parameters and locals).
    # `def_depth` is how many `def` or lambda bodies enclose this one;
    # the caller passes it, since each body gets its own Compiler.
    def self.compile_proc(
      body : Body,
      symbols : SymbolTable,
      params : Array(Param) = [] of Param,
      in_block : Bool = false,
      parent_scope : CompilerScope? = nil,
      def_depth : Int32 = 0,
      enclosing_method : String? = nil,
    ) : {Chunk, Int32}
      c = new(symbols, def_depth)
      c.enclosing_method = enclosing_method
      scope = CompilerScope.new(in_block, parent_scope)
      c.scope = scope
      slots = params.map { |param| scope.define(param.name) }
      c.emit_default_prologue(params, slots)
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

    # The method this code is being compiled inside, so a block can
    # record where it was written. Only R007's message reads it: a
    # block's own name is `<block>`, which names no call the reader
    # could fix.
    protected property enclosing_method : String?

    # -----------------------------------------------------------------------

    protected def compile_body(body : Body) : Nil
      if body.stmts.empty?
        emit_nil(body.line)
        return
      end
      body.stmts.each_with_index do |stmt, i|
        compile_node(stmt)
        # Pops every statement's value but the last, the body's value.
        @chunk.emit(Op::Pop, stmt.line) unless i == body.stmts.size - 1
      end
    end

    protected def emit_ret(line : Int32) : Nil
      @chunk.emit(Op::Ret, line)
    end

    # Emits, at the top of a proc's chunk, the code that evaluates
    # each omitted parameter's default, in declared order, so a
    # default can use earlier parameters: `def add(a, b = a + 1)`. Per
    # parameter with a default:
    #
    #   [HasKwarg name | GetArgc; Const(slot+1); Gte]; JumpIfTrue skip
    #   compile(default); SetLocal slot; Pop
    #   skip:
    #
    # A keyword is tested by name, a positional parameter by argument
    # count. `VM#bind_args` handles splats and missing required keywords
    # (R011); an omitted required positional parameter stays nil.
    protected def emit_default_prologue(params : Array(Param), slots : Array(Int32)) : Nil
      params.each_with_index do |param, i|
        next unless default = param.default
        slot = slots[i]
        line = param.line
        # Supplied or not: by name for a keyword, by count otherwise.
        if param.kwarg?
          @chunk.emit(Op::HasKwarg, line, c: intern(param.name))
        else
          @chunk.emit(Op::GetArgc, line)
          count_idx = @chunk.add_const(Value.int(i + 1))
          @chunk.emit(Op::Const, line, c: count_idx)
          @chunk.emit(Op::Gte, line)
        end
        skip_jump = @chunk.emit_jump(Op::JumpIfTrue, line)
        compile_node(default)
        @chunk.emit(Op::SetLocal, line, c: slot.to_u32)
        @chunk.emit(Op::Pop, line)
        @chunk.patch_jump(skip_jump, @chunk.pos)
      end
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
      when RegexFragment  then compile_regex_fragment(node)
      when RegexLiteral   then compile_regex(node)
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
      when AttrAssign     then compile_attr_assign(node)
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
        raise CompileError.new(
          Diagnostic.new(
            code: "I005",
            primary: Span.new(line: node.line, column: node.column),
            data: {"node" => node.class.to_s}
          )
        )
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
      # `_` separators are valid (`1_000`) but `to_i64` rejects them.
      raw = node.value.delete('_')
      n = raw.starts_with?("0x") || raw.starts_with?("0X") ? raw[2..].to_i64(16) : raw.to_i64
      idx = @chunk.add_const(Value.int(n))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_float(node : FloatLiteral) : Nil
      # `_` separators are valid (`1_000.5`) but `to_f64` rejects them.
      # The lexer has already checked their placement.
      idx = @chunk.add_const(Value.float(parse_float_lexeme(node.value.delete('_'))))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    # Parses a float lexeme, returning a signed 0.0 or Infinity when it
    # is out of Float64's range, as IEEE-754 and mruby do, instead of
    # raising. The true base-10 exponent (of the most significant
    # digit, with any `e` suffix) is computed from the digits, so a
    # 41-digit mantissa with `e-383` counts as about 1e-343. Only
    # lexemes clearly out of range, beyond +320 or -330, skip parsing.
    private def parse_float_lexeme(lexeme : String) : Float64
      # An all-zero mantissa is zero whatever its exponent; checked
      # first, since `0.0e400` would otherwise count as overflow.
      return signed_zero(lexeme) if all_zero_mantissa?(lexeme)

      exp = true_decimal_exponent(lexeme)
      if -330 <= exp <= 320
        # The margins are approximate, so `1.0e309` or `1.0e-325` can
        # still fail to parse; the fallback uses the same exponent to
        # choose 0.0 or Infinity.
        lexeme.to_f64? || out_of_range_result(lexeme, exp)
      else
        out_of_range_result(lexeme, exp)
      end
    end

    private def out_of_range_result(lexeme : String, exp : Int32) : Float64
      negative = lexeme.starts_with?('-')
      if exp > 0
        negative ? -Float64::INFINITY : Float64::INFINITY
      else
        signed_zero(lexeme)
      end
    end

    private def signed_zero(lexeme : String) : Float64
      lexeme.starts_with?('-') ? -0.0_f64 : 0.0_f64
    end

    private def all_zero_mantissa?(lexeme : String) : Bool
      s = lexeme.starts_with?('-') ? lexeme[1..] : lexeme
      mantissa, _, _ = s.partition(/[eE]/)
      mantissa.chars.all? { |char| char == '0' || char == '.' }
    end

    # The base-10 exponent of the lexeme's most significant digit,
    # including any `e` suffix, computed from the digits alone:
    # "123.45" gives 2, "0.00123" gives -3, "1.0e-400" gives -400.
    private def true_decimal_exponent(lexeme : String) : Int32
      s = lexeme.starts_with?('-') ? lexeme[1..] : lexeme
      mantissa, _, exp_part = s.partition(/[eE]/)
      explicit_exp = exp_part.empty? ? 0 : exp_part.to_i32

      int_part, _, frac_part = mantissa.partition('.')
      int_part = int_part.lstrip('0')
      base_exp = if !int_part.empty?
                   int_part.size - 1
                 else
                   stripped = frac_part.lstrip('0')
                   leading_zeros = frac_part.size - stripped.size
                   -(leading_zeros + 1)
                 end
      base_exp + explicit_exp
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
      # A missing bound (`1..`, `..10`) is compiled as nil.
      if start_node = node.start_node
        compile_node(start_node)
      else
        emit_nil(node.line)
      end
      if end_node = node.end_node
        compile_node(end_node)
      else
        emit_nil(node.line)
      end
      @chunk.emit(Op::MakeRange, node.line, a: node.exclusive? ? 1_u8 : 0_u8)
    end

    private def compile_regex_fragment(node : RegexFragment) : Nil
      idx = @chunk.add_const(Value.string(node.value))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    # Compiles a regex literal's parts into one pattern String, joined
    # with Concat as for an interpolated string, then emits MakeRegex
    # with the flags as a bitmask.
    private def compile_regex(node : RegexLiteral) : Nil
      node.parts.each { |part| compile_node(part) }
      @chunk.emit(Op::Concat, node.line, a: node.parts.size.to_u8)
      @chunk.emit(Op::MakeRegex, node.line, a: encode_regex_flags(node.flags))
    end

    # Encodes "imx" flag letters as the `Builtins` option bitmask.
    private def encode_regex_flags(flags : String) : UInt8
      bits = 0
      bits |= Builtins::IGNORECASE if flags.includes?('i')
      bits |= Builtins::EXTENDED if flags.includes?('x')
      bits |= Builtins::MULTILINE if flags.includes?('m')
      bits.to_u8
    end

    # --- Variables ----------------------------------------------------------

    private def compile_identifier(node : Identifier) : Nil
      name = node.name
      if scope = @scope
        if slot = scope.resolve_local(name)
          @chunk.emit(Op::GetLocal, node.line, c: slot.to_u32)
          return
        end
        if depth_slot = scope.resolve_outer(name)
          depth, slot = depth_slot
          @chunk.emit(Op::GetOuter, node.line, a: depth.to_u8, c: slot.to_u32)
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
      when TokenKind::EqTilde
        compile_match(node)
      when TokenKind::BangTilde
        compile_match(node)
        @chunk.emit(Op::Not, node.line)
      when TokenKind::NEq
        compile_node(node.left)
        compile_node(node.right)
        @chunk.emit(Op::Eq, node.line)
        @chunk.emit(Op::Not, node.line)
      when TokenKind::TripleEq
        compile_triple_eq(node)
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
      # `b: 0b10` marks `node.left` as the receiver, so `<=>`
      # dispatches on it.
      @chunk.emit(Op::Call, node.line, a: 2_u8, b: 0b10_u16, c: sym_idx)
    end

    # `x =~ y` compiles to the call `x.=~(y)`. `x !~ y` is the same
    # followed by `Not`, as Ruby defines it.
    private def compile_match(node : Binary) : Nil
      compile_node(node.left)
      compile_node(node.right)
      sym_idx = intern("=~")
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      @chunk.emit(Op::Call, node.line, a: 2_u8, b: 0b10_u16, c: sym_idx)
    end

    # `a === b` compiles to the fixed `TripleEq` opcode, not a method
    # call; like `==`, it can't be overridden. Operands are pushed
    # subject first (`b`, then `a`), the order `case`/`when` produces
    # naturally, and `TripleEq` pops them in that order.
    private def compile_triple_eq(node : Binary) : Nil
      compile_node(node.right)
      compile_node(node.left)
      @chunk.emit(Op::TripleEq, node.line)
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
        # No position: only the token kind is known here.
        raise CompileError.new(
          Diagnostic.new(code: "I006", data: {"operator" => op.to_s})
        )
      end
    end

    # --- Unary --------------------------------------------------------------

    private def compile_unary(node : Unary) : Nil
      compile_node(node.expr)
      case node.op
      when TokenKind::Bang  then @chunk.emit(Op::Not, node.line)
      when TokenKind::Minus then @chunk.emit(Op::Neg, node.line)
      when TokenKind::Plus  then @chunk.emit(Op::Pos, node.line)
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
      # `x += y` compiles as `x = x + y`.
      compile_node(node.target)
      compile_node(node.value)
      @chunk.emit(binary_op(node.op), node.line)
      emit_store(node.target, node.line)
    end

    private def compile_cond_assign(node : CondAssign) : Nil
      # `x ||= y` assigns only if x is falsy; `x &&= y` only if truthy.
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

    # Stores the value on top of the stack into `target`. Constants are
    # stored with SetConstant.
    private def emit_store(target : Node, line : Int32) : Nil
      case target
      when Identifier
        emit_store_name(target.name, line)
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
        # The value was pushed before this store, so the stack holds
        # `[value, target, index]`, the reverse of
        # `compile_index_assign`'s order; `SetIndexFromValue` pops
        # this order.
        compile_node(target.target)
        compile_node(target.index)
        @chunk.emit(Op::SetIndexFromValue, line)
      else
        raise CompileError.new(
          Diagnostic.new(
            code: "C001",
            primary: Span.new(
              line: target.line,
              column: target.column,
              label: "not assignable"
            ),
            data: {"target" => describe_node(target)}
          )
        )
      end
    end

    # --- Calls --------------------------------------------------------------

    # Stores the top of the stack into the variable `name`: a local of
    # this scope, else an enclosing scope's local, else a new local.
    # `force_define`, for `rescue => e`, skips enclosing scopes and
    # always defines a local here, as Ruby binds a rescue variable
    # locally even inside a block.
    private def emit_store_name(name : String, line : Int32, force_define : Bool = false) : Nil
      if scope = @scope
        if slot = scope.resolve_local(name)
          @chunk.emit(Op::SetLocal, line, c: slot.to_u32)
          return
        end
        if !force_define && (depth_slot = scope.resolve_outer(name))
          depth, slot = depth_slot
          @chunk.emit(Op::SetOuter, line, a: depth.to_u8, c: slot.to_u32)
          return
        end
        # In a block, a name found in no scope is stored as a global,
        # not a block-local as in Ruby.
        if force_define || !scope.is_block?
          slot = scope.define(name)
          @chunk.emit(Op::SetLocal, line, c: slot.to_u32)
          return
        end
      end
      sym_idx = intern(name)
      @chunk.emit(Op::SetGlobal, line, c: sym_idx)
    end

    private def compile_call(node : Call) : Nil
      if recv = node.receiver
        compile_node(recv)
      end
      node.args.each { |arg| compile_node(arg) }
      # Keyword arguments: (name symbol, value) pairs, as for
      # MakeHash, staged by SetKwargNames for the Call.
      unless node.kwargs.empty?
        node.kwargs.each do |(name, value)|
          @chunk.emit(Op::Const, node.line, c: intern(name))
          compile_node(value)
        end
        @chunk.emit(Op::SetKwargNames, node.line, a: node.kwargs.size.to_u8)
      end
      # A block is pushed by MakeProc and staged by SetBlock.
      if blk = node.block
        blk_params = blk.params.map(&.name)
        blk_chunk, blk_locals = Compiler.compile_proc(
          blk.body, @symbols,
          params: blk.params,
          in_block: true,
          parent_scope: @scope,
          def_depth: @def_depth,
          enclosing_method: @enclosing_method
        )
        sproc = ScriptProc.new(blk_chunk, "<block>", blk_params, blk_locals, true,
          ast_params: blk.params, home_method: @enclosing_method)
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

    # `recv.attr = value` calls the setter `attr=`. The receiver is
    # evaluated once, before the value. `SetAttr` pops value then
    # receiver and pushes the value back: an assignment's value is what
    # was assigned, not what the setter returns.
    private def compile_attr_assign(node : AttrAssign) : Nil
      compile_node(node.receiver)
      compile_node(node.value)
      sym_idx = intern("#{node.method}=")
      @chunk.emit(Op::SetAttr, node.line, c: sym_idx)
    end

    # --- Definitions --------------------------------------------------------

    # Runs the block with a fresh scope for a class or module body:
    # no `parent`, so it can't see enclosing locals, and slots
    # numbered on from the enclosing scope, whose frame it shares.
    private def with_nested_scope(&) : Nil
      outer = @scope
      start = outer.try(&.next_slot) || 0
      @scope = CompilerScope.new(is_block: false, parent: nil, starting_slot: start)
      yield
      @scope = outer
    end

    # The L001 error, shared by the three sites that check loop
    # nesting.
    private def loop_too_deep(node : Node) : CompileError
      CompileError.new(
        Diagnostic.new(
          code: "L001",
          primary: Span.new(
            line: node.line,
            column: node.column,
            label: "nesting limit reached here"
          ),
          data: {"limit" => MAX_LOOP_DEPTH.to_s}
        )
      )
    end

    # How an unassignable target reads to a script author, keyed by AST
    # class so a renamed class breaks the build.
    NODE_DESCRIPTIONS = Hash(Node.class, String){
      Call          => "a method call",
      IntLiteral    => "a number",
      FloatLiteral  => "a number",
      StringLiteral => "a string",
      InterpString  => "a string",
      SymbolLiteral => "a symbol",
      ArrayLiteral  => "an array literal",
      HashLiteral   => "a hash literal",
      RangeLiteral  => "a range",
      NilLiteral    => "`nil`",
      BoolLiteral   => "`true`/`false`",
      SelfNode      => "`self`",
      Binary        => "the result of an expression",
      Unary         => "the result of an expression",
      Ternary       => "the result of an expression",
    }

    private def describe_node(node : Node) : String
      NODE_DESCRIPTIONS[node.class]? || "this expression"
    end

    # Operator method names a script can't define (U017): each compiles
    # to a fixed opcode that never consults a class's methods, so a
    # definition would never run. `<=>` is absent because `<`, `<=`,
    # `>` and `>=` dispatch to a script's `<=>`. `[]` and `[]=` are
    # absent because they can't be lexed as one method name.
    OVERLOADABLE_OPERATOR_NAMES = Set{
      "==", "===", "<", "<=", ">", ">=",
      "+", "-", "*", "/", "%",
      "&", "|", "^", "<<", ">>",
    }

    private def def_signature(node : DefNode) : String
      prefix =
        case recv = node.receiver
        when SelfNode   then "self."
        when Identifier then "#{recv.name}."
        else                 ""
        end
      "def #{prefix}#{node.name}"
    end

    private def compile_def(node : DefNode) : Nil
      if OVERLOADABLE_OPERATOR_NAMES.includes?(node.name)
        # Rejected before anything else about the def. The caret
        # covers `def`, since DefNode has no end position.
        raise CompileError.new(
          Diagnostic.new(
            code: "U017",
            primary: Span.new(
              line: node.line,
              column: node.column,
              length: 3,
              label: "not overloadable"
            ),
            data: {"operator" => node.name}
          )
        )
      end
      if @def_depth > 0
        # A `def` inside a `def` or lambda body (U004), with or
        # without a receiver. It would define a method whenever the
        # enclosing one runs, so a class's methods would depend on
        # what has been called. Defs at top level or directly in a
        # class or module body run once and are fine.
        raise CompileError.new(
          Diagnostic.new(
            code: "U004",
            primary: Span.new(
              line: node.line,
              # The caret covers `def`: DefNode has no end position,
              # and the gap before the name can vary.
              column: node.column,
              length: 3,
              label: "not allowed here"
            ),
            data: {"definition" => def_signature(node)}
          )
        )
      end
      if blk_param = node.params.find(&.block_param?)
        # `&blk` parameters are excluded (U001): a block is reachable
        # only through `yield`.
        raise CompileError.new(
          Diagnostic.new(
            code: "U001",
            primary: Span.new(
              line: blk_param.line,
              column: blk_param.column,
              # `&` plus the name; the column is the `&`.
              length: blk_param.name.size + 1,
              label: "not usable as a value"
            ),
            data: {
              "param"  => blk_param.name,
              "method" => node.name,
            }
          )
        )
      end
      params = node.params.map(&.name)
      body_chunk, local_count = Compiler.compile_proc(
        node.body, @symbols,
        params: node.params,
        in_block: false,
        def_depth: @def_depth + 1,
        enclosing_method: node.name
      )
      sproc = ScriptProc.new(body_chunk, node.name, params, local_count, false,
        ast_body: node.body, ast_params: node.params)
      proc_idx = @chunk.add_const(Value.proc(sproc))
      @chunk.emit(Op::MakeProc, node.line, c: proc_idx)
      sym_idx = intern(node.name)
      if recv = node.receiver
        compile_node(recv)
        @chunk.emit(Op::DefSingleton, node.line, c: sym_idx)
      else
        # `def` defines on self's class. At top level self is `main`,
        # so the method goes on Object, as in Ruby.
        @chunk.emit(Op::DefMethod, node.line, c: sym_idx)
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
      with_nested_scope { compile_body(node.body) }                    # [old_self, body_val]
      @chunk.emit(Op::Pop, node.line)                                  # [old_self]  discard body value
      @chunk.emit(Op::SetClass, node.line)                             # []  self := old_self (restored)
      emit_nil(node.line)                                              # [nil]  class-def statement's own value
    end

    private def compile_module(node : ModuleNode) : Nil
      name_idx = intern(node.name)

      @chunk.emit(Op::GetClass, node.line)                 # [old_self]
      @chunk.emit(Op::MakeModule, node.line, c: name_idx)  # [old_self, new_module]
      @chunk.emit(Op::SetConstant, node.line, c: name_idx) # [old_self, new_module]
      @chunk.emit(Op::SetClass, node.line)                 # [old_self]  self := new_module
      with_nested_scope { compile_body(node.body) }        # [old_self, body_val]
      @chunk.emit(Op::Pop, node.line)                      # [old_self]
      @chunk.emit(Op::SetClass, node.line)                 # []  self := old_self (restored)
      emit_nil(node.line)                                  # [nil]
    end

    private def compile_lambda(node : Lambda) : Nil
      params = node.params.map(&.name)
      lam_chunk, local_count = Compiler.compile_proc(
        node.body, @symbols,
        params: node.params,
        in_block: true,
        parent_scope: @scope,
        enclosing_method: @enclosing_method,
        # A lambda can run later and repeatedly, like a method, so a
        # `def` inside it is nested; a block's body keeps the depth
        # unchanged.
        def_depth: @def_depth + 1
      )
      sproc = ScriptProc.new(lam_chunk, "<lambda>", params, local_count, true,
        ast_params: node.params)
      proc_idx = @chunk.add_const(Value.proc(sproc))
      # a=1 wraps the proc as a Proc object; def bodies and block
      # literals use a=0.
      @chunk.emit(Op::MakeProc, node.line, a: 1_u8, c: proc_idx)
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
      raise loop_too_deep(node) if @loop_stack.size >= MAX_LOOP_DEPTH
      loop_start = @chunk.pos
      scope = LoopScope.new(loop_start, ensure_depth_at_entry: @ensure_stack.size)
      @loop_stack.push(scope)

      compile_node(node.cond)
      # `until` inverts the condition.
      @chunk.emit(Op::Not, node.line) if node.until_loop?
      jmp_exit = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      # LoopScope is a struct, so `body_pos` is written back through
      # the array index; `@loop_stack.last.body_pos =` would change a
      # copy. It can't be set before the push, as the other loops do,
      # because it is only known after the condition is compiled.
      current = @loop_stack[-1]
      current.body_pos = @chunk.pos
      @loop_stack[-1] = current

      compile_body(node.body)
      @chunk.emit(Op::Pop, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)
      @chunk.patch_jump(jmp_exit, @chunk.pos)

      # The loop's value when the condition ends it is nil. A `break`
      # has already pushed its own value, so breaks are patched past
      # this nil.
      emit_nil(node.line)
      tail = @chunk.pos

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, tail) }
    end

    private def compile_loop(node : LoopNode) : Nil
      raise loop_too_deep(node) if @loop_stack.size >= MAX_LOOP_DEPTH
      loop_start = @chunk.pos
      scope = LoopScope.new(loop_start, ensure_depth_at_entry: @ensure_stack.size)
      scope.body_pos = loop_start
      @loop_stack.push(scope)

      compile_body(node.body)
      @chunk.emit(Op::Pop, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)

      # Only a `break` leaves `loop`, and it has already pushed its
      # value, so breaks are patched past this nil.
      emit_nil(node.line)
      after_nil = @chunk.pos

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, after_nil) }
    end

    private def compile_for(node : ForNode) : Nil
      # `for i in expr ... end` compiles as `expr.each { |i| ... }`.
      compile_node(node.iter) # receiver: the iterable

      # Loop variables are plain names, so plain Params are built for
      # them, at the loop's own position.
      for_params = node.vars.map { |name| Param.new(name, nil, false, false, false, node.line, node.column) }
      blk_chunk, blk_locals = Compiler.compile_proc(
        node.body, @symbols,
        params: for_params,
        in_block: true,
        parent_scope: @scope,
        def_depth: @def_depth,
        enclosing_method: @enclosing_method
      )
      sproc = ScriptProc.new(blk_chunk, "<block>", node.vars, blk_locals, true,
        ast_params: for_params, home_method: @enclosing_method)
      proc_idx = @chunk.add_const(Value.proc(sproc))
      @chunk.emit(Op::MakeProc, node.line, c: proc_idx)
      @chunk.emit(Op::SetBlock, node.line)

      sym_idx = intern("each")
      # One argument, the receiver (`0b10`), as for `expr.each { }`.
      @chunk.emit(Op::Call, node.line, a: 1_u8, b: 0b10_u16, c: sym_idx)
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
            # The stack is `[subject, pattern]`, the order `TripleEq`
            # pops.
            @chunk.emit(Op::Dup, node.line)
            compile_node(pat)
            @chunk.emit(Op::TripleEq, node.line)
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

    # Before a `break`, `next` or `redo` jumps out of begin regions,
    # emits `EnterEnsure` for each region deeper than `target_depth`,
    # innermost first, followed by its ensure body and a Pop. This runs
    # the ensure code and pops each handler, which would otherwise
    # catch a later, unrelated error. A value the jump carries is left
    # in place.
    #
    # `target_depth` is `@ensure_stack.size` at the jump's target: a
    # loop's `ensure_depth_at_entry`, or 0 when leaving a block, since
    # each block body has its own Compiler and `@ensure_stack`.
    private def emit_ensure_unwind(target_depth : Int32, line : Int32) : Nil
      exiting = @ensure_stack.size - target_depth
      return if exiting <= 0
      exiting.times do |i|
        region = @ensure_stack[@ensure_stack.size - 1 - i]
        @chunk.emit(Op::EnterEnsure, line)
        if ensure_body = region.ensure_body
          compile_body(ensure_body)
          @chunk.emit(Op::Pop, line)
        end
      end
    end

    private def compile_break(node : BreakNode) : Nil
      if v = node.value
        compile_node(v)
      else
        emit_nil(node.line)
      end
      if !@loop_stack.empty?
        emit_ensure_unwind(@loop_stack.last.ensure_depth_at_entry, node.line)
        jmp = @chunk.emit_jump(Op::Jump, node.line)
        @loop_stack.last.breaks << jmp
      else
        emit_ensure_unwind(0, node.line)
        @chunk.emit(Op::BlockBreak, node.line)
      end
    end

    private def compile_next(node : NextNode) : Nil
      if !@loop_stack.empty?
        if v = node.value
          compile_node(v)
          @chunk.emit(Op::Pop, node.line)
        end
        emit_ensure_unwind(@loop_stack.last.ensure_depth_at_entry, node.line)
        @chunk.emit(Op::Jump, node.line, c: @loop_stack.last.start_pos.to_u32)
      else
        if v = node.value
          compile_node(v)
        else
          emit_nil(node.line)
        end
        emit_ensure_unwind(0, node.line)
        @chunk.emit(Op::Ret, node.line)
      end
    end

    private def compile_redo(node : RedoNode) : Nil
      if @loop_stack.empty?
        raise CompileError.new(
          Diagnostic.new(
            code: "C002",
            primary: Span.new(
              line: node.line,
              column: node.column,
              length: 4,
              label: "no loop to restart"
            )
          )
        )
      end
      # `redo` restarts the loop body, which is outside any begin
      # region opened in it.
      emit_ensure_unwind(@loop_stack.last.ensure_depth_at_entry, node.line)
      @chunk.emit(Op::Jump, node.line, c: @loop_stack.last.body_pos.to_u32)
    end

    private def compile_yield(node : YieldNode) : Nil
      node.args.each { |arg| compile_node(arg) }
      @chunk.emit(Op::Yield, node.line, a: node.args.size.to_u8)
    end

    private def compile_super(node : SuperNode) : Nil
      # Bare `super` forwards the method's current parameter values,
      # read from the frame when it runs, so reassigned parameters
      # pass their new values.
      if node.forwarded?
        @chunk.emit(Op::Super, node.line, b: 1_u16)
        return
      end
      node.args.each { |arg| compile_node(arg) }
      @chunk.emit(Op::Super, node.line, a: node.args.size.to_u8)
    end

    # --- Exception handling -------------------------------------------------

    private def compile_begin(node : BeginNode) : Nil
      if node.rescue_clauses.empty? && node.ensure_body.nil?
        compile_body(node.body)
        return
      end

      has_rescue = !node.rescue_clauses.empty?
      try_at, ensure_at = emit_try_and_ensure_setup(node, has_rescue)

      # Only the body is inside this region: a `break` in a rescue or
      # ensure clause has already left it.
      @ensure_stack.push(EnsureRegion.new(node.ensure_body))
      compile_body(node.body)
      @ensure_stack.pop
      @chunk.emit(Op::EndTry, node.line) if has_rescue

      # `else` runs only when the body raised nothing, after the rescue
      # handler is cleared, so its own errors propagate. Its value
      # replaces the body's.
      if else_body = node.else_body
        @chunk.emit(Op::Pop, node.line)
        compile_body(else_body)
      end

      if try_pos = try_at
        compile_rescue_clauses(node, try_pos)
      end

      if ensure_body = node.ensure_body
        if ea = ensure_at
          @chunk.patch_jump(ea, @chunk.pos)
        end
        @chunk.emit(Op::EnterEnsure, node.line)
        compile_body(ensure_body)
        # The ensure body's value is discarded.
        @chunk.emit(Op::Pop, node.line)
        # Re-raises the error the ensure was entered with, if any.
        @chunk.emit(Op::EndEnsure, node.line)
      end
    end

    # Emits `Try` if there is a rescue clause, and `SetEnsure` if
    # there is an ensure body, returning their indices for patching.
    # An ensure-only `begin` catches nothing, so gets no `Try`.
    private def emit_try_and_ensure_setup(node : BeginNode, has_rescue : Bool) : {Int32?, Int32?}
      try_at = @chunk.emit_jump(Op::Try, node.line) if has_rescue
      ensure_at = if node.ensure_body
                    # b: 1 tells the VM to add this target to the
                    # entry the preceding Try just pushed (same
                    # construct), rather than pushing a second entry.
                    b = has_rescue ? 1_u16 : 0_u16
                    @chunk.emit(Op::SetEnsure, node.line, b: b, c: Chunk::NO_TARGET)
                  end
      {try_at, ensure_at}
    end

    # Compiles the rescue clauses in source order; the first whose
    # classes match wins. With no match, the error is re-raised
    # unchanged.
    private def compile_rescue_clauses(node : BeginNode, try_at : Int32) : Nil
      jmp_past_rescue = @chunk.emit_jump(Op::Jump, node.line)
      @chunk.patch_jump(try_at, @chunk.pos)

      match_done_jumps = [] of Int32
      node.rescue_clauses.each do |clause|
        no_match_jump = compile_rescue_clause_test(node, clause)
        compile_rescue_bind_and_body(clause)
        match_done_jumps << @chunk.emit_jump(Op::Jump, node.line)
        @chunk.patch_jump(no_match_jump, @chunk.pos)
      end

      # No clause matched: re-raise the original error.
      @chunk.emit(Op::PushError, node.line)
      @chunk.emit(Op::Reraise, node.line)

      match_done_jumps.each { |j| @chunk.patch_jump(j, @chunk.pos) }
      @chunk.patch_jump(jmp_past_rescue, @chunk.pos)
    end

    # Emits one clause's class test and returns the jump taken when
    # nothing matches, for the caller to patch.
    private def compile_rescue_clause_test(node : BeginNode, clause : RescueClause) : Int32
      # A clause with no classes catches StandardError, as in Ruby.
      classes = clause.classes.empty? ? [Constant.new("StandardError", node.line, node.column)] of Node : clause.classes

      match_jumps = [] of Int32
      no_match_jump = 0
      classes.each_with_index do |cls, i|
        @chunk.emit(Op::PushError, node.line)
        compile_node(cls)
        # `error.is_a?(rescue_class)`.
        nil_idx = @chunk.add_const(Value.nil_value)
        @chunk.emit(Op::Const, node.line, c: nil_idx)
        @chunk.emit(Op::SetBlock, node.line)
        is_a_sym = intern("is_a?")
        @chunk.emit(Op::Call, node.line, a: 2_u8, b: 0b10_u16, c: is_a_sym)
        if i == classes.size - 1
          # The last class: no match means the clause misses.
          no_match_jump = @chunk.emit_jump(Op::JumpIfFalse, node.line)
        else
          # A match jumps to the clause body; a miss tries the next
          # class.
          match_jumps << @chunk.emit_jump(Op::JumpIfTrue, node.line)
        end
      end
      match_jumps.each { |j| @chunk.patch_jump(j, @chunk.pos) }
      no_match_jump
    end

    private def compile_rescue_bind_and_body(clause : RescueClause) : Nil
      if rvar = clause.var
        @chunk.emit(Op::PushError, clause.body.line)
        emit_store_name(rvar, clause.body.line, force_define: true)
        @chunk.emit(Op::Pop, clause.body.line)
      end
      compile_body(clause.body)
    end

    # `retry` is excluded (U020): it is rejected here.
    private def compile_retry(node : RetryNode) : Nil
      raise CompileError.new(
        Diagnostic.new(
          code: "U020",
          primary: Span.new(
            line: node.line,
            column: node.column,
            length: 5, # "retry"
            label: "retry is not supported"
          )
        )
      )
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
      # `alias` compiles to the runtime call `__alias__(new, old)`.
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
      # `x = begin...end while cond` is the do-while form (U016),
      # which runs its body before the first check. The bare statement
      # is rejected by the parser.
      if begin_node = do_while_begin(node.body)
        raise CompileError.new(
          Diagnostic.new(
            code: "U016",
            primary: Span.new(
              line: begin_node.line,
              column: begin_node.column,
              length: 5, # "begin"
              label: "do-while form not supported"
            )
          )
        )
      end

      # `expr while cond` checks first, like a `while` statement, so
      # the body may run zero times.
      raise loop_too_deep(node) if @loop_stack.size >= MAX_LOOP_DEPTH
      loop_start = @chunk.pos
      scope = LoopScope.new(loop_start, ensure_depth_at_entry: @ensure_stack.size)
      @loop_stack.push(scope)

      compile_node(node.cond)
      @chunk.emit(Op::Not, node.line) if node.until_loop?
      jmp_exit = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      # Written through the index: LoopScope is a struct.
      current = @loop_stack[-1]
      current.body_pos = @chunk.pos
      @loop_stack[-1] = current

      compile_node(node.body)
      @chunk.emit(Op::Pop, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)
      @chunk.patch_jump(jmp_exit, @chunk.pos)

      # The loop's value when the condition ends it is nil. A `break`
      # has already pushed its own value, so breaks are patched past
      # this nil.
      emit_nil(node.line)
      tail = @chunk.pos

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, tail) }
    end

    # The BeginNode that makes a ModifierWhile a do-while: the body
    # itself, or the value of an assignment that is the body
    # (`x = begin...end while cond`, `x += ...`). Nil for anything
    # else, including a `begin` nested deeper.
    private def do_while_begin(node : Node) : BeginNode?
      case node
      when BeginNode  then node
      when Assign     then node.value.as?(BeginNode)
      when OpAssign   then node.value.as?(BeginNode)
      when CondAssign then node.value.as?(BeginNode)
      end
    end

    # --- Helpers ------------------------------------------------------------

    private def intern(name : String) : UInt32
      sym = @symbols.intern(name)
      @chunk.add_const(Value.symbol(sym))
    end
  end
end
