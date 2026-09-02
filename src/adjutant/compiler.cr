require "./ast"
require "./bytecode"
require "./diagnostic"
require "./builtins/regexp"

module Adjutant
  class CompileError < Exception
    getter line : Int32
    getter column : Int32

    # Present only for raise sites migrated to the diagnostic system.
    # Nil means this error predates that migration and carries just a
    # message — the two forms coexist deliberately, so converting the
    # ~70 raise sites can happen incrementally instead of as one
    # unreviewable change.
    getter diagnostic : Diagnostic?

    def initialize(message : String, @line, @column)
      @diagnostic = nil
      super("#{message} (line #{line}, col #{column})")
    end

    # `message` stays a readable one-liner so existing rescuers and
    # specs keep working; anything wanting the source snippet renders
    # `diagnostic` through `DiagnosticRenderer`.
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

    # Snapshot of @ensure_stack.size at the point this loop was
    # entered — how many begin/rescue/ensure regions were ALREADY
    # open around the loop itself, as opposed to opened fresh inside
    # its body. compile_break/compile_next diffs this against the
    # current @ensure_stack.size to find how many regions a jump back
    # to this loop's start/exit needs to unwind THROUGH (running their
    # ensure bodies and popping their VM handler entries) rather than
    # jump straight past. See EnsureRegion below for why this can't
    # just be "the loop's own nesting" — a loop can sit inside a
    # begin/ensure that was opened before the loop existed.
    property ensure_depth_at_entry : Int32

    def initialize(@start_pos, @body_pos = 0, @ensure_depth_at_entry = 0)
      @breaks = [] of Int32
    end
  end

  # One lexically-open begin/rescue/ensure construct, tracked only
  # while the compiler is walking inside it — pushed by compile_begin
  # before compiling its body/rescue/ensure, popped after. Exists
  # purely so compile_break/compile_next can see, at compile time,
  # which ensure bodies (if any) a jump out of a loop is skipping
  # past, the same way @loop_stack lets them see which loop start/end
  # they're jumping to. Deliberately separate from LoopScope: a begin/
  # ensure and a loop nest independently of each other (a loop can
  # open inside a begin, or a begin can open inside a loop), so this
  # needs its own stack rather than being folded into LoopScope.
  #
  # ensure_body is nil for a rescue-only construct (no ensure clause)
  # — still tracked here, because break/next skipping over it leaves
  # the SAME stale HandlerEntry problem (rescue_ip set, never cleared
  # via Op::EndTry) even with no ensure code to run. In that case
  # compile_break/compile_next emit Op::EnterEnsure alone (pop the
  # handler, run nothing) rather than skipping this region entirely.
  private struct EnsureRegion
    property ensure_body : Body?

    def initialize(@ensure_body)
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

    # `starting_slot` is deliberately independent from `parent`/
    # `is_block` — it's pure slot-numbering bookkeeping, not name
    # visibility. A class/module body shares its enclosing frame
    # (unlike a def/block body, which gets its own fresh Frame via
    # call_script_proc — see compile_proc/Op::MakeProc), so its own
    # CompilerScope must continue slot numbering where the enclosing
    # scope left off, or Op::SetLocal inside the body would silently
    # overwrite an outer local living at the same Frame.locals index.
    # It must NOT set `parent` to achieve this — `parent` is what
    # `resolve_outer` uses for real closure capture (blocks reading
    # an enclosing method's locals live), and a class/module body
    # must NOT see its enclosing scope's locals at all:
    #
    #   module A
    #     tmp_a = 55
    #     module B
    #       tmp_b = 66
    #       puts tmp_a  # real Ruby: NameError — B cannot see A's tmp_a
    #     end
    #   end
    #
    # `is_block: false, parent: nil, starting_slot: <wherever A left
    # off>` is exactly right here: B's own CompilerScope resolves
    # `tmp_a` as unresolved (falls through past locals — same
    # NameError path as any other undefined bare identifier) while
    # still allocating `tmp_b` a slot number that can't collide with
    # `tmp_a`'s, since both live in the one Frame this whole program
    # (or this whole class/module nest) is executing in.
    def initialize(@is_block = false, @parent = nil, starting_slot : Int32 = 0)
      @vars = {} of String => Int32
      @next_slot = starting_slot
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

    # Resolve a name somewhere in the full lexical chain of enclosing
    # scopes (block/lambda closure capture, at ANY depth — not just
    # the immediate parent). Returns {depth, slot}: depth counts how
    # many closure-creation hops out the name lives (0 = the scope
    # that was ACTIVE when THIS scope's own block/lambda was written
    # — i.e. the immediate parent's own vars; 1 = one hop further,
    # ...), matching EXACTLY how Frame#outer_locals (OuterChain,
    # vm.cr) is built at runtime: each hop out is one more prepended
    # chain entry. `slot` is the variable's own index within THAT
    # level's locals array — unrelated to depth, since every level
    # numbers its own locals independently.
    #
    # Found 2026-08-10 (SCOPE.md's "Closures / block scoping" entry):
    # this used to check only `@parent.vars` directly (one hop) and
    # give up — a name declared two or more block/lambda-creation
    # hops out was invisible, even though `parent` ALREADY forms a
    # proper chain all the way out (every block/lambda's
    # `compile_proc` call passes `parent_scope: @scope` — see those
    # call sites) and the runtime `OuterChain` (Step 1) already had
    # the data available once created; the gap was purely this walk
    # stopping too early. The chain naturally terminates at a `def`'s
    # own root scope without any extra check here — `compile_def`
    # never passes `parent_scope` at all (a `def` doesn't close over
    # its lexical surroundings in Ruby, regardless of where it's
    # written), so that scope's own `parent` is already nil.
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

    # Compile a full top-level program body. Returns {chunk, local_count}
    # — same shape as compile_proc, and for the same reason: top-level
    # code needs real local-variable scoping too (previously it had
    # none at all, so every bare `x = 5` at top level silently became
    # a global — see CompilerScope#initialize's `starting_slot` comment
    # and with_nested_scope for the related class/module-body fix).
    # The top-level scope is a genuine root — no parent, not a block —
    # so it behaves exactly like a method body's own scope: first
    # assignment to an unresolved name defines a new local (see
    # emit_store's `unless scope.is_block?` branch), not a global.
    def self.compile(body : Body, symbols : SymbolTable) : {Chunk, Int32}
      c = new(symbols)
      scope = CompilerScope.new(is_block: false, parent: nil)
      c.scope = scope
      c.compile_body(body)
      {c.chunk, scope.next_slot}
    end

    # Compile a method/block body.
    # Returns {chunk, local_count} — local_count is the number of frame
    # slots the body needs (params + locals defined in the body).
    #
    # `def_depth` — how many `def`/lambda bodies this body is already
    # lexically nested inside, propagated by the CALLER (see
    # `compile_def`/`compile_lambda`'s own `@def_depth + 1`, and the
    # two block-compiling call sites' `@def_depth` passthrough) rather
    # than tracked here, because a nested proc body is compiled by a
    # BRAND NEW `Compiler` instance (`c = new(symbols, def_depth)`
    # below) — an ordinary instance ivar on the OUTER compiler
    # wouldn't be visible to it at all. Read by `compile_def` on the
    # instance that's about to compile a NESTED `def` node, to reject
    # it before ever emitting `Op::DefMethod`/`Op::DefSingleton` — see
    # that method's own comment for why this exists.
    # `params` takes full `Param` nodes (not bare names) specifically
    # so this method can emit the default-value prologue below —
    # every real caller (compile_def, compile_lambda, the block-
    # literal branch of compile_call) has the full `Param`s on hand
    # from the AST already; only `compile_for`'s synthetic `each`
    # desugar has bare names (loop variables can't carry `=`/`*`
    # syntax), which is why that one call site builds plain `Param`s
    # with no default/splat instead of changing this signature twice.
    def self.compile_proc(
      body : Body,
      symbols : SymbolTable,
      params : Array(Param) = [] of Param,
      in_block : Bool = false,
      parent_scope : CompilerScope? = nil,
      def_depth : Int32 = 0,
    ) : {Chunk, Int32}
      c = new(symbols, def_depth)
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

    # Emits, at the very top of a proc's chunk (before any body
    # statement), one conditional block per param that has a
    # `default` — the piece of the argument-binding fix that VM#
    # bind_args (vm.cr) explicitly leaves undone, because evaluating
    # an arbitrary default expression means running compiled bytecode,
    # which only the compiler can produce and only `execute` can run;
    # bind_args is plain Crystal with neither.
    #
    # Per param with a default, in declared order:
    #   [HasKwarg name | GetArgc; Const(slot+1); Gte]; JumpIfTrue → skip
    #     (true means the caller DID supply this slot, so JumpIfTrue is
    #     "skip the default, it's not needed")
    #   [falls through here when omitted:]
    #     compile(default expression); SetLocal slot; Pop
    #   skip:
    #
    # The two bracketed forms are the ONLY difference between a kwarg
    # default and an ordinary positional one — everything else in this
    # method is shared. A kwarg's "was this supplied?" test is by
    # NAME (Op::HasKwarg), since kwargs don't occupy a fixed position
    # at all; an ordinary param's is by argc count, where `slot+1` (not
    # `slot`) accounts for argc being 1-based ("how many args came
    # in") while `slot` is a 0-based index — the param at slot i is
    # supplied exactly when argc >= i+1.
    #
    # A default expression can reference earlier params (`def add(a, b
    # = a + 1)`) — this works unremarkably because `compile_node`
    # resolves `a` against `scope`, and every earlier param is already
    # `scope.define`d (and, if it's own default applied, already
    # `SetLocal`-written into its slot) by the time a later default
    # compiles, since this method walks params in the same declared
    # order they were defined in.
    #
    # Splat and plain required params are skipped here entirely —
    # splat collection is pure Array slicing with nothing to evaluate,
    # so VM#bind_args does it directly with no bytecode needed. A
    # required param with no default — kwarg or not — has nothing to
    # fall back to and is unaffected by this method at all: an
    # ordinary one is silently left at nil_value if the caller omitted
    # it (permissive, as always); a REQUIRED kwarg is instead raised
    # on directly by VM#bind_args (R011) the moment it's found
    # missing, since there's a fixed fact to report and no expression
    # to evaluate — this method never even sees it (the `next unless
    # default = param.default` guard below skips it immediately).
    protected def emit_default_prologue(params : Array(Param), slots : Array(Int32)) : Nil
      params.each_with_index do |param, i|
        next unless default = param.default
        slot = slots[i]
        line = param.line
        # A required kwarg with no default (missing → VM#bind_args
        # raises directly, no bytecode needed) never reaches here at
        # all — only a kwarg WITH a default does, same as any other
        # param below. The two branches differ only in how "was this
        # slot actually supplied?" is tested: by name (HasKwarg) for a
        # kwarg, by position count (GetArgc) for everything else.
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
      # Same underscore-stripping need as compile_float below, and for
      # the same reason: Lexer#scan_digit_run allows a single `_`
      # between two digits for INTEGER literals too, not just float
      # ones (matches Ruby's own grammar — `1_000` is a plain Integer)
      # — but String#to_i64 defaults to underscore: false, so a raw
      # `"1_000".to_i64` would raise. Stripped here rather than passing
      # `underscore: true` to to_i64/to_i64(16), to keep this symmetric
      # with compile_float's approach and avoid a second underscore
      # rule living in two different places.
      raw = node.value.delete('_')
      n = raw.starts_with?("0x") || raw.starts_with?("0X") ? raw[2..].to_i64(16) : raw.to_i64
      idx = @chunk.add_const(Value.int(n))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    private def compile_float(node : FloatLiteral) : Nil
      # Underscores are valid in the lexeme (Lexer#scan_digit_run
      # allows a single `_` strictly between two digits, matching
      # Ruby's actual literal grammar) but Crystal's String#to_f64 has
      # no underscore support at all (unlike String#to_i, which does)
      # — must strip them here or `to_f64` raises on a lexeme like
      # "1_000.5". By the time a FloatLiteral reaches the compiler the
      # lexer has already validated underscore placement (trailing/
      # doubled underscores never make it into the lexeme in the first
      # place), so a blind strip is safe — no re-validation needed.
      idx = @chunk.add_const(Value.float(parse_float_lexeme(node.value.delete('_'))))
      @chunk.emit(Op::Const, node.line, c: idx)
    end

    # Parses a float lexeme, rounding gracefully to a signed 0.0 or
    # signed Infinity on underflow/overflow instead of raising —
    # matching IEEE-754's own defined behavior (and mruby's own float
    # parser, which this was found to diverge from via mruby's test
    # suite: `1.0e-400`, `9.99e-344`, and
    # `-92170141183460469231731687303715884105729e-383` must all round
    # cleanly rather than error). `String#to_f64` raises ArgumentError
    # on an out-of-Float64-range string; `#to_f64?` (nilable) merely
    # swallows that into `nil` with NO signal about which direction the
    # range was exceeded or what the correctly-rounded result should
    # be (confirmed empirically — asked the person to run `to_f64?` on
    # exactly these four literals in a real Crystal REPL, since this
    # can't be observed from this clone-only workspace; all four
    # returned nil, confirming to_f64? alone isn't enough to implement
    # this correctly).
    #
    # So: compute the TRUE base-10 exponent of the lexeme ourselves,
    # via plain string/integer arithmetic (no float parsing involved,
    # so no precision or range concerns of our own) — the exponent of
    # the most-significant digit, folding in any explicit `e`/`E`
    # suffix. A 41-digit mantissa with `e-383` isn't actually at
    # magnitude 1e-383; it's at roughly 9.2e-342 (40 + -383 = -343),
    # and getting this combination right is the entire point (the
    # naive "just look at the e-suffix" approach would misjudge this
    # literal's true magnitude by 40+ orders of magnitude). Compare
    # against generous, deliberately non-tight bounds around Float64's
    # actual range (Float64::MAX is ~1.8e308, smallest positive
    # subnormal is ~5e-324) — ±320/-330 leaves comfortable margin on
    # both sides so this only ever activates for genuinely, unambiguously
    # out-of-range literals, never a normal one near the boundary by
    # coincidence (the exact boundary is still handled correctly
    # regardless, since anything in the generous safe range still goes
    # through ordinary `to_f64`, which is exact there).
    private def parse_float_lexeme(lexeme : String) : Float64
      # An all-zero mantissa is always exactly 0.0/-0.0 regardless of
      # its exponent (0 * 10^anything is 0) — checked BEFORE computing
      # true_decimal_exponent, which would otherwise misjudge
      # "0.0e400"'s exponent as a huge POSITIVE number (since it treats
      # an all-zero mantissa the same as a genuine leading zero run,
      # e.g. "0.00123"'s -3), incorrectly routing it into the overflow
      # branch below and returning Infinity for a literal that's
      # mathematically zero. Found by explicitly checking this exact
      # shape before considering the fix complete, not by inspection.
      return signed_zero(lexeme) if all_zero_mantissa?(lexeme)

      exp = true_decimal_exponent(lexeme)
      if -330 <= exp <= 320
        # Still go through to_f64? here, not a raw to_f64 — the
        # exponent-range check above is a deliberately approximate
        # margin (Float64::MAX's true exponent is ~308.25, smallest
        # positive subnormal's is ~-323.3, neither a round number), NOT
        # a promise that everything in this range actually fits.
        # Found by explicitly checking "1.0e309" (true exponent 309,
        # comfortably inside the +320 margin, but genuinely over
        # Float64::MAX) and "1.0e-325" (true exponent -325, inside the
        # -330 margin, but genuinely below the smallest subnormal) —
        # both would still raise via a raw to_f64 call. On a nil here,
        # out_of_range_result falls back to the same sign-aware
        # 0.0-vs-Infinity choice the always-out-of-range branch below
        # uses, keyed off the SAME already-computed `exp` — a nil in
        # this branch does NOT always mean overflow (see the -325
        # case above).
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

    # The base-10 exponent of the lexeme's most-significant digit,
    # folding in any explicit `e`/`E` suffix — e.g. "123.45" -> 2
    # (1.2345 * 10^2), "0.00123" -> -3 (1.23 * 10^-3), "1.0e-400" -> -400,
    # "92170141183460469231731687303715884105729e-383" -> -343 (a
    # 41-digit integer part normalizes to exponent 40, combined with
    # the explicit -383). Pure string/integer arithmetic — no float
    # parsing, so no range limits of its own to worry about, which is
    # exactly why this is computed BEFORE deciding whether to trust
    # to_f64 with the actual parse.
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
      # A missing bound (endless/beginless range) compiles to a plain
      # `nil` literal on the stack — Op::MakeRange/make_range_object
      # already accept and store a nil Value unconditionally (the same
      # path `Range.new(nil, x)` already used before this syntax
      # parsed at all; see builtins/range.cr's own comment on that
      # constructor). No VM/opcode change needed for construction
      # itself — only #each/#step/#to_a and to_s/#inspect still need
      # real nil-bound handling, tracked separately in SCOPE.md.
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

    # Compiles a regex literal's parts down to a single pattern String
    # on the stack (via Concat — see compile_interp_string, which this
    # mirrors exactly, including for the non-interpolated case: a
    # plain `/abc/` literal still arrives here as a single-fragment
    # RegexLiteral, so Concat with a=1 is always the path, not a
    # special case), then emits Op::MakeRegex with the flag letters
    # encoded into a bitmask VM#make_regexp_object can decode without
    # re-parsing strings at runtime.
    private def compile_regex(node : RegexLiteral) : Nil
      node.parts.each { |part| compile_node(part) }
      @chunk.emit(Op::Concat, node.line, a: node.parts.size.to_u8)
      @chunk.emit(Op::MakeRegex, node.line, a: encode_regex_flags(node.flags))
    end

    # "imx" letters (Token#regex_flags / RegexLiteral#flags, always
    # some subset of these three per the lexer's scan_regex_flags) →
    # Builtins::IGNORECASE/EXTENDED/MULTILINE bitmask, the same
    # encoding Builtins.regex_options expects on the runtime side.
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
      # `b: 0b10` marks `node.left` (already on the stack, pushed first
      # above) as the RECEIVER, not a plain argument — the same
      # receiver bit `compile_call` sets for every ordinary `.` call.
      # Without it, `dispatch_call` never even attempts receiver-based
      # method lookup on `left`; it falls through to implicit-self
      # dispatch against whatever frame happens to be compiling `<=>`,
      # which is essentially never `left`'s own class. Found
      # 2026-08-06 while wiring `<`/`<=`/`>`/`>=` through `<=>` (see
      # SCOPE.md) — a real, independent bug that predates this item:
      # `a <=> b` has never actually dispatched on `a` at all.
      @chunk.emit(Op::Call, node.line, a: 2_u8, b: 0b10_u16, c: sym_idx)
    end

    # `x =~ y` desugars to the ordinary receiver call `x.=~(y)` —
    # identical shape to `compile_spaceship` just above (a real
    # `Op::Call` with the receiver bit set, not a raw VM opcode), just
    # interning `"=~"` instead of `"<=>"` and with no derived-
    # comparison logic to also emit, since `=~`'s result (a match
    # position or nil) IS the whole answer already.
    #
    # Also reused as-is for `!~` (see `compile_binary`'s own
    # `BangTilde` case) — real Ruby's `!~` is generically
    # `!(self =~ other)`, always via `=~` itself, never a separate
    # `!~` method dispatch of its own (matching how `!=`/`NEq` just
    # below reuses `==`'s own machinery rather than being its own
    # thing) — so `BangTilde` just appends one `Op::Not` after calling
    # this, unconditionally, rather than duplicating this whole method
    # to intern `"!~"` instead.
    private def compile_match(node : Binary) : Nil
      compile_node(node.left)
      compile_node(node.right)
      sym_idx = intern("=~")
      nil_idx = @chunk.add_const(Value.nil_value)
      @chunk.emit(Op::Const, node.line, c: nil_idx)
      @chunk.emit(Op::SetBlock, node.line)
      @chunk.emit(Op::Call, node.line, a: 2_u8, b: 0b10_u16, c: sym_idx)
    end

    # `a === b` — deliberately NOT method dispatch, unlike `<=>`/`=~`
    # just above (`compile_spaceship`/`compile_match`, both real
    # `Op::Call`s with the receiver bit set). `===` joined `==` in
    # `OVERLOADABLE_OPERATOR_NAMES` (see that set's own comment) —
    # neither is script-overridable, both are fixed VM opcodes that
    # never consult a class's method table, same as `+`/`-`/indexing.
    # `Op::TripleEq` (`vm.cr`'s own comment on it) hardcodes the
    # Class/Range/Regexp/Proc special-casing directly, mirroring what
    # `Op::Eq` already does for plain `==` — not a receiver dispatch
    # that HAPPENS to always resolve to the same fixed set today.
    #
    # Operand push order is REVERSED from the ordinary left-then-right
    # shape every other binary op here uses (including `==`/`Op::Eq`
    # right above `compile_binary`'s own `TripleEq` case) — deliberate,
    # not a mistake: `compile_case`'s own per-`when`-pattern check
    # (`compile_case`, below) shares this exact same opcode, and ITS
    # natural stack order — push the subject once up front, `Op::Dup`
    # it, then push each `when` pattern on top — puts subject BELOW
    # pattern, not above. Rather than add a new stack-shuffling opcode
    # (a `Swap`, or `compile_case`'s subject via a synthetic local
    # instead of a stack `Dup` — SCOPE.md's now-resolved "missing
    # receiver bit" entry considered both) just to make `compile_case`
    # match the ordinary left-then-right convention, this method
    # matches `compile_case`'s naturally-cheaper order instead: push
    # `node.right` (the SUBJECT — `b` in `a === b`) first, `node.left`
    # (the PATTERN — `a`) second. `Op::TripleEq`'s own VM handler
    # therefore expects `(subject, pattern)` off the stack, not
    # `(pattern, subject)` — see its own comment for the actual
    # `Class#===`/`Range#===`/etc. matching logic, which takes the
    # arguments in THAT order for exactly this reason.
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
        # No position: this maps a token kind to an opcode and never
        # sees the node it came from.
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
    # Every scope (top-level, class/module body, method, block) has a
    # real CompilerScope after the 2026-07-15 scoping fix — bare
    # identifiers are locals everywhere now, not just inside a method/
    # block. The SetGlobal fallback below is unreachable in practice
    # for a bare Identifier (every Compiler instance gets @scope set
    # immediately after construction — see Compiler.compile/
    # compile_proc), kept only as a defensive fallback rather than
    # asserting @scope is never nil.
    # Constants are lexically scoped — see SetConstant.
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
        # NOT Op::SetIndex (see compile_index_assign, above/below,
        # for the ONLY other emitter of that opcode) — a genuinely
        # different opcode, `Op::SetIndexFromValue`, because this
        # branch runs in a genuinely different STACK STATE than
        # `compile_index_assign` does.
        #
        # `compile_index_assign` pushes `[target, index, value]`, in
        # that order — value LAST, matching `Op::SetIndex`'s pop
        # contract (`val = pop; idx = pop; target = pop`) exactly.
        # This branch, by contrast, is reached only from
        # `compile_op_assign`/`compile_cond_assign`/
        # `compile_multi_assign`, every one of which has ALREADY
        # pushed the value being assigned before `emit_store` ever
        # runs (see each of their own top-of-method `compile_node
        # (node.value)`/equivalent) — so by the time control reaches
        # HERE, the value is sitting at the BOTTOM of what will become
        # a 3-element group, not the top. Pushing `target` then
        # `index` on top of it gives `[value, target, index]` — the
        # OPPOSITE order from `compile_index_assign`'s.
        #
        # Found 2026-08-08, entirely by accident, via an unrelated
        # spec (`x[i] += 1` inside a receiver-side-effect regression
        # for the same session's `AttrAssign` work) — before this fix,
        # BOTH call sites emitted the identical `Op::SetIndex`, so the
        # VM's single, fixed pop order (`val, idx, target`) was only
        # ever correct for ONE of them. For this branch's actual
        # `[value, target, index]` stack shape, that fixed pop order
        # reads: `val` ends up holding `index`, `idx` ends up holding
        # `target`, and `target` ends up holding the ORIGINAL value —
        # completely scrambled, then handed to `exec_set_index` as
        # nonsense types. No test had ever exercised `x[i] += 1` (or
        # `||=`/`&&=`/multi-assign into an index) before this,
        # confirmed by grepping the full spec suite — this had been
        # silently broken (in practice, a silent no-op, since
        # `exec_set_index` on the resulting garbage types quietly
        # does nothing rather than crashing) since whenever this
        # branch was first written. See `Op::SetIndexFromValue`'s own
        # comment (bytecode.cr) and its VM handler (vm.cr) for the
        # matching pop-order fix; see assignment/vm_spec.cr and
        # assignment/compiler_spec.cr for the regression coverage.
        compile_node(target.target)
        compile_node(target.index)
        @chunk.emit(Op::SetIndexFromValue, line)
      else
        raise CompileError.new(
          Diagnostic.new(
            code: "C001",
            primary: Span.new(
              line: target.line,
              # Was hardcoded to column 0, which is not a real column —
              # the target node has known its own position all along.
              column: target.column,
              label: "not assignable"
            ),
            data: {"target" => describe_node(target)}
          )
        )
      end
    end

    # --- Calls --------------------------------------------------------------

    # The actual name-resolution-and-emit logic for storing into a
    # bare identifier — factored out of emit_store's Identifier case
    # so a non-assignment binding that still needs "put this name in
    # the current scope" (currently only compile_rescue_bind_and_body,
    # for `rescue => e`) can share it instead of hardcoding SetGlobal.
    # `rescue e` used to do exactly that — bind unconditionally via
    # Op::SetGlobal, leaking `e` out of the rescue block as a real
    # global and colliding with any top-level `def e` of the same
    # name, same bug shape as the 2026-07-15 scoping fix, just never
    # caught by that pass since it's a hardcoded emission rather than
    # a path through emit_store itself.
    # `force_define`: for `rescue => e` (see
    # compile_rescue_bind_and_body) — real Ruby always binds a rescue
    # variable as a genuine local of the enclosing body, even inside a
    # block, unlike ordinary assignment. Concretely this means: still
    # reuse an EXISTING same-scope local of that name if there is one
    # (resolve_local still runs first, same as ordinary assignment),
    # but never reach into an enclosing scope via resolve_outer, and
    # never fall through to a global if truly unresolved — a rescue
    # binding isn't "maybe an existing OUTER variable the user meant
    # to update"; it's the language guaranteeing a local scoped to
    # right here.
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
        # In a block, an unresolved name falls through to global —
        # blocks don't introduce new locals for names they can't see.
        # In a non-block scope (method, top-level, class/module body),
        # first assignment defines a new local. force_define skips
        # straight here regardless of is_block?, for the reason above.
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
      # Keyword args, if any: push (name symbol, value) pairs — same
      # alternating convention Op::MakeHash uses — then SetKwargNames
      # to stage them for the Call below. Only emitted when there
      # actually are some, so the overwhelming majority of calls (no
      # keyword args at all) never touch this path.
      unless node.kwargs.empty?
        node.kwargs.each do |(name, value)|
          @chunk.emit(Op::Const, node.line, c: intern(name))
          compile_node(value)
        end
        @chunk.emit(Op::SetKwargNames, node.line, a: node.kwargs.size.to_u8)
      end
      # Register block if present — MakeProc pushes it, SetBlock pops it
      if blk = node.block
        blk_params = blk.params.map(&.name)
        blk_chunk, blk_locals = Compiler.compile_proc(
          blk.body, @symbols,
          params: blk.params,
          in_block: true,
          parent_scope: @scope,
          def_depth: @def_depth
        )
        sproc = ScriptProc.new(blk_chunk, "<block>", blk_params, blk_locals, true,
          ast_params: blk.params)
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

    # `recv.attr = value` (a real receiver-based setter call, dispatch
    # resolved the same way any other method call is — user-defined
    # `attr=`/`attr_writer`/`attr_accessor` first, R008 undefined-
    # method if nothing answers). `receiver` is compiled exactly ONCE,
    # before `value` — matching `compile_index_assign`'s own
    # target-then-value push order immediately above, not the
    # value-then-target order `emit_store`'s generic (OpAssign/
    # CondAssign/MultiAssign-only) `Index` case uses; a `Call`
    # receiver could have side effects (`get_config().name = x`), and
    # evaluating it more than once, or in a different position each
    # time, would silently diverge from real Ruby, which evaluates a
    # receiver expression exactly once for any single assignment. This
    # is exactly why `AttrAssign` is its own AST node built directly
    # by the parser (see that node's own comment, ast.cr) rather than
    # routed through `emit_store`'s generic per-target-kind dispatch,
    # which — as things stand today (`Index`'s case, specifically) —
    # is only ever reached from OpAssign/CondAssign/MultiAssign, never
    # from a plain `Assign` (`a[i] = v` has its own dedicated
    # `IndexAssign` node too, same reasoning), and pushes in the
    # opposite order from `compile_index_assign`'s dedicated path —
    # copying that shape here would have reproduced the same
    # ordering inconsistency for attribute assignment instead of
    # avoiding it.
    #
    # `Op::SetAttr` pops value then receiver (reverse of the push
    # order above) and pushes `value` back — matching every other
    # Set* opcode's convention (`Op::SetIvar`/`Op::SetIndex`/...): an
    # assignment expression's own value is always the value assigned,
    # never whatever the setter method itself happens to return.
    private def compile_attr_assign(node : AttrAssign) : Nil
      compile_node(node.receiver)
      compile_node(node.value)
      sym_idx = intern("#{node.method}=")
      @chunk.emit(Op::SetAttr, node.line, c: sym_idx)
    end

    # --- Definitions --------------------------------------------------------

    # A class/module body's own local-variable scope. Fresh
    # CompilerScope (`parent: nil, is_block: false`) so names defined
    # inside are invisible both outside the body (once popped, @scope
    # reverts to the outer one, whose `vars` was never touched) and to
    # any OUTER local of the same name (no `parent` link means
    # resolve_local/resolve_outer can never see past this scope's own
    # `vars`, matching real Ruby: a class/module body does not close
    # over its enclosing scope's locals the way a block does). Slot
    # numbering continues from the outer scope's `next_slot` (NOT a
    # fresh 0) because a class/module body runs in the SAME Frame as
    # its enclosing code — unlike a def/block body, which gets its own
    # Frame via call_script_proc, a class/module body is never a
    # separate ScriptProc/MakeProc/call at all (see compile_class/
    # compile_module: no compile_proc call, just inline compile_body
    # with self swapped via Op::SetClass). Two different CompilerScope
    # objects sharing one Frame.locals array would silently collide at
    # the SAME slot index without this.
    private def with_nested_scope(&) : Nil
      outer = @scope
      start = outer.try(&.next_slot) || 0
      @scope = CompilerScope.new(is_block: false, parent: nil, starting_slot: start)
      yield
      @scope = outer
    end

    # Three sites guard the same limit, so the diagnostic is built in
    # one place rather than repeated.
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

    # What the author wrote, for an unassignable target. AST class
    # names are internal (`IntegerLit`, `CallNode`) and mean nothing to
    # a script author, so the common cases get named in their terms.
    # Keyed on the class objects, not on class-NAME strings: this way
    # the compiler checks them, so renaming or removing an AST class
    # breaks the build rather than silently degrading every affected
    # diagnostic to the generic wording. A lookup rather than a `case`
    # keeps it to one branch — as a `case` this was sixteen type tests
    # and over Ameba's complexity threshold.
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

    # How the definition was written, for diagnostics: `def foo`,
    # `def self.foo`, `def obj.foo`. Reconstructed rather than sliced
    # out of the source, since the compiler has no access to it.
    # Every operator-token method name except `<=>` — see
    # UNSUPPORTED.md's U017. `<=>` is the one deliberate exception (see
    # SCOPE.md's Must Fix entry): `Op::Lt`/`Le`/`Gt`/`Ge` dispatch
    # through a script-defined `<=>` for `RubyObject` operands, but
    # every other operator (arithmetic, `==`, `===`, indexing)
    # compiles to a fixed opcode that never consults a class's method
    # table, so a method by one of these names would parse cleanly and
    # then never actually run — exactly the silent trap this set
    # exists to catch instead. Real Ruby's `<=>`/`Comparable` split is
    # the model: `<=>` is overridable, plain `==` (`Object#==`,
    # identity by default) deliberately is not derived from it, and
    # neither is anything else here.
    #
    # `"==="` joined this set 2026-08-07, once the lexer grew a real
    # `TripleEq` token (`lexer.cr`'s `scan_eq`) for the sole purpose of
    # letting `def ===` reach this check at all — before that, `"==="`
    # split into `EqEq` + a stray `Eq`, and `def ===(x)` failed with a
    # confusing, unrelated-looking `P002` partway through the method
    # body instead of this clean, named rejection. `===` now compiles
    # to its own fixed opcode too (`Op::TripleEq`, `vm.cr` —
    # `compile_triple_eq` below, plus `compile_case`'s per-`when`-
    # pattern check, both emit it directly), same shape `Op::Eq`
    # already has for `==`, so this rejection and bare infix `a ===
    # b`/`case/when` support coexist without conflict, same as every
    # other operator here — the fixed opcode's own hardcoded
    # `Class`/`Range`/`Regexp`/`Proc` special-casing (see
    # `triple_eq_matches?`, vm.cr) is exactly what a script-defined
    # `def ===` would otherwise have silently never reached anyway.
    #
    # `[]`/`[]=` are the one remaining case deliberately NOT in this
    # set (see UNSUPPORTED.md) — same reason `"==="` needed a token
    # first: `[` and `]` are separate lexer tokens with no combined
    # `[]`/`[]=` token, so `parse_def` (which takes whatever single
    # token follows `def` as the name, unconditionally) already can't
    # produce a `DefNode` with that name at all; it grabs `[` alone,
    # then trips on the stray `]` with the same shape of confusing,
    # unrelated parse error `"==="` used to. A name this check will
    # never see doesn't belong in the set actually being checked
    # against — unless, like `"==="`, it gets its own token someday.
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
        # Checked before @def_depth (below) and before any other
        # compile_def work — this rejects the method name itself,
        # independent of nesting or anything else about the def.
        # Carets the `def` keyword, not the operator name itself:
        # `DefNode` has no end position, and the name's own column
        # would need reconstructing through an optional `self.`/
        # `recv.` prefix of variable width to land correctly (see
        # def_signature above) — same tradeoff U004 below already
        # makes for the identical reason, three characters that are
        # always right beating a longer span that's only usually
        # right.
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
        # Rejects `def`/`def self.foo` lexically nested inside ANOTHER
        # `def`'s (or lambda's) body — e.g. `def outer; def inner;
        # end; end` — regardless of receiver. Originally this was
        # caught (incompletely) at RUNTIME, and only for the `def
        # self.foo` shape specifically (see the removed guard in
        # Op::DefSingleton, vm.cr) — reasoning at the time was "a real
        # per-instance singleton table would let an object's method set
        # diverge from its class," which is true but named the wrong
        # mechanism: a PLAIN `def inner` (no `self.`) nested the same
        # way hits `Op::DefMethod` instead, which was never guarded at
        # all, and — confirmed empirically by the person, 2026-07-27 —
        # writes directly into the ENCLOSING CLASS's ordinary instance
        # method table. That's not a narrower, safer version of the
        # per-instance-singleton problem; it's the SAME problem
        # (runtime-conditional method definition, discoverable only by
        # simulating execution, undermining "an object's callable
        # surface is knowable from its class alone") reached through a
        # different, unguarded door — `x.test` permanently added
        # `nested` to the WHOLE class, visible to every other instance
        # including ones constructed after the fact.
        #
        # So the real boundary was never "singleton vs instance method"
        # or "which opcode" — it's "does this def execute exactly once,
        # synchronously, as part of establishing the class" (top level,
        # or directly inside a class/module body — both fine, both
        # unaffected by this check) "or does it execute later,
        # conditionally, as part of calling some OTHER already-defined
        # method" (not fine, rejected here). Checked at COMPILE time
        # now rather than runtime — strictly earlier and more complete:
        # every case the old runtime check caught is a def lexically
        # nested this way by construction (self can only BE a non-main
        # RubyObject inside another method's own body to begin with),
        # so this check is a superset, not a narrower replacement.
        #
        # `@def_depth` is propagated through `compile_proc` (see that
        # method's own comment) rather than tracked as a simple ivar,
        # because a nested proc body compiles via a BRAND NEW `Compiler`
        # instance — ivar state on this instance wouldn't reach it.
        raise CompileError.new(
          Diagnostic.new(
            code: "U004",
            primary: Span.new(
              line: node.line,
              # `parse_def` records its position before consuming `def`,
              # so the column is the keyword. The caret covers just the
              # keyword rather than reaching to the method name:
              # `DefNode` has no end position, and reconstructing the
              # width from `def ` plus the name would assume exactly
              # one space, which `def  foo` breaks. Three characters
              # that are always right beat a longer span that is
              # usually right.
              column: node.column,
              length: 3,
              label: "not allowed here"
            ),
            data: {"definition" => def_signature(node)}
          )
        )
      end
      if blk_param = node.params.find(&.block_param?)
        # `&blk` param capture is a deliberate scope decision
        # (see UNSUPPORTED.md, U001) — a `{ }`/`do...end` block passed
        # to a call stays reachable only via implicit `yield` inside
        # that same call; it never becomes a value a script can hold, pass
        # around, or defer-call. Rejected HERE, at compile time, rather
        # than left to silently bind nothing (which is what happened
        # before this guard: `blk` inside the method body was just
        # always `nil`, so `blk.call` failed with a generic, confusing
        # R008, undefined method or variable `call`, instead of a clear
        # explanation of what's actually unsupported and why).
        raise CompileError.new(
          Diagnostic.new(
            code: "U001",
            primary: Span.new(
              line: blk_param.line,
              column: blk_param.column,
              # `&` plus the name. `parse_param` captures the position
              # BEFORE consuming the `&`, so the column already points
              # at the sigil and the span covers exactly what the
              # author wrote.
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
        def_depth: @def_depth + 1
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
        # `def` always targets self's class (see Op::DefMethod) —
        # true everywhere now, not just "inside a class/module body":
        # top-level self is `main`, a real RubyObject whose class is
        # Object, so a bare top-level `def` correctly becomes a method
        # of Object (matching real Ruby exactly) via the SAME opcode a
        # class body's `def` uses. No more @class_depth branch/
        # Op::SetGlobal special case for "am I at top level."
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
        # Incremented, not propagated unchanged — a lambda IS a real,
        # first-class `Proc` value a script can store and invoke later,
        # arbitrarily many times (see the a=1 comment below) — same
        # "runs conditionally, possibly repeatedly" category as a def
        # body for compile_def's nested-def guard, not the same
        # category as an ordinary block (which can only run
        # synchronously via `yield`, during the one call that received
        # it — see the two OTHER compile_proc call sites, which
        # propagate @def_depth unchanged instead).
        def_depth: @def_depth + 1
      )
      sproc = ScriptProc.new(lam_chunk, "<lambda>", params, local_count, true,
        ast_params: node.params)
      proc_idx = @chunk.add_const(Value.proc(sproc))
      # a=1: wrap as a real Proc RubyObject (see vm.cr Op::MakeProc,
      # builtins/proc.cr). def bodies and call-site block literals
      # (Compiler's other two Value.proc(sproc) sites) pass a=0 (the
      # default) and stay bare — see SCOPE.md Piece C scope boundary.
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
      # For `until`, invert the condition
      @chunk.emit(Op::Not, node.line) if node.until_loop?
      jmp_exit = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      # LoopScope is a struct (value type): @loop_stack.push(scope)
      # above already copied it onto the array, so mutating the local
      # `scope` variable from here on (as the pre-existing code below
      # already did for `breaks`, and previously also did for
      # body_pos) does NOT reach the copy the array holds. `breaks`
      # happens to work anyway because Array(Int32) is a reference —
      # the local's `breaks` and the array copy's `breaks` are two
      # struct fields pointing at the SAME underlying Array object, so
      # pushes to either are visible through both. `body_pos` has no
      # such rescue: Int32 is a value, so writing scope.body_pos here
      # only ever changed the local's own copy, never the one
      # @loop_stack.last actually returns.
      #
      # Found 2026-08-05: pre-existing, present already in HEAD before
      # this session's changes (confirmed via git stash) — completely
      # independent of the break/next/ensure work. Every redo inside a
      # `while`/`until` loop jumped to @loop_stack.last.body_pos's
      # struct DEFAULT (0), not the real body start — index 0 of
      # whatever chunk was being compiled, not even necessarily inside
      # this loop at all. In a top-level script that's index 0 of the
      # whole program, meaning `redo` silently re-ran everything from
      # the top, re-initializing any locals declared before the loop
      # (e.g. a counter reset to its original value) — an infinite
      # loop for any redo whose only exit condition depended on such a
      # counter ever advancing. Never caught before because no test in
      # this repo's history had ever executed `redo` through the VM at
      # all (see spec/adjutant/begin_rescue_ensure/vm_spec.cr's redo tests
      # for the confirming grep and the bounded regression coverage).
      #
      # Fixed by a read-modify-write through the array INDEX
      # (@loop_stack[-1] = ...), not `.last.body_pos =` — `.last`
      # itself returns another copy for a struct element, same trap
      # one level down, so `.last.body_pos = x` would compile cleanly
      # and silently do nothing, identically to the original bug.
      # compile_loop/compile_modifier_while avoid the whole problem by
      # setting body_pos before pushing instead, baking the correct
      # value into the copy at push time — that approach doesn't work
      # here, since body_pos for a `while` isn't known until AFTER the
      # condition and its JumpIfFalse are compiled (loop_start is the
      # condition check; body_pos is the position right after it).
      current = @loop_stack[-1]
      current.body_pos = @chunk.pos
      @loop_stack[-1] = current

      compile_body(node.body)
      @chunk.emit(Op::Pop, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)
      @chunk.patch_jump(jmp_exit, @chunk.pos)

      # Fallthrough (condition went false, no break) has nothing on
      # the stack yet for this expression's value — push nil here,
      # same as an unbroken loop always evaluates to. A break, by
      # contrast, already pushed its OWN value before jumping
      # (compile_break) — landing on this same emit_nil and falling
      # through it would push a second, spurious nil on top of that
      # value (found 2026-08-05 by a test that made a broken-with-
      # value while loop the last statement in a script, the one
      # context where the extra nil isn't silently discarded by some
      # later Pop). So breaks must NOT land here — patch them past
      # this emit_nil instead, to the shared point both paths reach
      # with exactly one value on the stack.
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

      # `loop do ... end` has no natural fallthrough exit — the Jump
      # above is unconditional, so nothing reaches emit_nil below
      # except a break's patched jump landing on it directly (there's
      # no separate "condition went false" path to protect the way
      # compile_while has, since this form has no condition at all).
      # Still must NOT let breaks land on and fall through emit_nil,
      # though: every break already pushed its own value
      # (compile_break), so falling through would push a second,
      # spurious nil on top of it. Patch breaks to AFTER emit_nil, not
      # to the position emit_nil itself starts at (found 2026-08-05 by
      # a test making a broken-with-value `loop` the last statement in
      # a script — see compile_while's identical fix for the fuller
      # writeup of why no prior test caught this).
      emit_nil(node.line)
      after_nil = @chunk.pos

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, after_nil) }
    end

    private def compile_for(node : ForNode) : Nil
      # Desugar: `for i in expr do body end` → `expr.each { |i| body }`
      #
      # Two bugs fixed here together (both silent, neither raised a
      # compile error):
      #   1. The receiver bit was never set on the emitted Call, so
      #      `expr` was pushed as a bare *argument* to a receiverless
      #      `each` instead of as the receiver — `each` was dispatched
      #      as an undefined global call ("undefined method or
      #      variable: each"), never reaching Array#each/etc at all.
      #   2. The "block" was a hardcoded nil constant — node.vars and
      #      node.body were never compiled into a real block, so even
      #      with (1) fixed the for-body would never have run.
      compile_node(node.iter) # receiver: the iterable

      # `node.vars` is `Array(String)` (a `for` loop var can't carry
      # `=`/`*`/`:` syntax — see ForNode), so this builds plain,
      # metadata-free Params rather than changing compile_proc's
      # signature back for one caller. No per-var position exists on
      # ForNode to attribute these to individually; node's own
      # line/column is the closest honest position, and it's dead
      # weight anyway — emit_default_prologue skips every one of
      # these (`default` is always nil).
      for_params = node.vars.map { |name| Param.new(name, nil, false, false, false, node.line, node.column) }
      blk_chunk, blk_locals = Compiler.compile_proc(
        node.body, @symbols,
        params: for_params,
        in_block: true,
        parent_scope: @scope,
        def_depth: @def_depth
      )
      sproc = ScriptProc.new(blk_chunk, "<block>", node.vars, blk_locals, true,
        ast_params: for_params)
      proc_idx = @chunk.add_const(Value.proc(sproc))
      @chunk.emit(Op::MakeProc, node.line, c: proc_idx)
      @chunk.emit(Op::SetBlock, node.line)

      sym_idx = intern("each")
      # argc: 1 — the receiver alone, no additional args; recv_bit set
      # (0b10) so dispatch treats the pushed value as a receiver, not
      # an argument, exactly matching what compile_call emits for a
      # real `expr.each { ... }` call.
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
            # Stack, right before `Op::TripleEq`: `[subject(dup), pattern]`
            # — subject deeper, pattern on top. This is `Op::TripleEq`'s
            # own expected `(subject, pattern)` order (see that op's
            # comment in vm.cr, and `compile_triple_eq`'s comment on why
            # bare-infix `a === b` pushes in this same, no-restructuring-
            # needed order rather than the reverse) — no receiver bit,
            # no method dispatch, no `Swap` opcode: this replaced a real
            # `Op::Call` to a `"==="` symbol (see SCOPE.md's now-resolved
            # "missing receiver bit" entry) now that `===` is a fixed
            # opcode like `==`, never script-overridable.
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

    # A break/next/redo whose target (loop exit, loop start, loop body
    # restart, or — for break/next inside a BLOCK with no enclosing
    # loop at all — the end of the block's own body) lies outside one
    # or more begin/rescue/ensure regions must run those regions'
    # ensure bodies (if any) and pop their VM handler entries before
    # the jump/return — otherwise it lands past Op::EnterEnsure,
    # silently skipping the ensure body's side effects and leaving a
    # stale HandlerEntry on Frame#handlers that could wrongly intercept
    # a later, unrelated error in the same frame. See SCOPE.md's now-
    # resolved Must Fix entry for the full bug writeup.
    #
    # Innermost-first is required, not incidental: it's the same order
    # real Ruby runs nested ensures in when unwinding, and it's also
    # the only order where each region's Op::EnterEnsure pops the
    # correct top-of-stack HandlerEntry (they were pushed outermost-
    # first, so they must come off in the reverse order).
    #
    # Any value already pushed by the caller (break's return value —
    # next's is popped before this runs, so there's nothing live to
    # protect in that case) is left alone: each drained region's own
    # ensure body pushes and pops exactly one value of its own (see
    # compile_begin's identical Pop-after-compile_body convention), so
    # the stack is balanced before and after this runs regardless.
    #
    # `target_depth` is how deep `@ensure_stack` was at the JUMP
    # TARGET (not at the break/next/redo site itself) — the loop case
    # passes `loop.ensure_depth_at_entry` (a loop can sit inside an
    # ensure region opened OUTSIDE it, in the SAME Compiler instance,
    # so that snapshot is genuinely needed). The no-loop-stack case
    # (break/next inside a block, nothing enclosing) always passes 0
    # — no snapshot needed there at all, because `Compiler.compile_proc`
    # gives every block/method body its OWN brand-new `Compiler`
    # instance with a FRESH `@ensure_stack`; nothing on it can ever
    # belong to anything outside the current body, so "the target" is
    # always "zero regions open" by construction.
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
      # Same bug shape as break/next (see emit_ensure_unwind's own
      # comment): body_pos is a position INSIDE the loop, before any
      # begin/rescue/ensure nested in the body was entered, so a redo
      # from inside such a region needs the same handler-draining
      # treatment — not "no loop to jump to" territory like break/next's
      # loop-stack-empty branch, but the same "jump target is outside
      # currently-open ensure regions" territory as their loop-stack-
      # nonempty branch.
      emit_ensure_unwind(@loop_stack.last.ensure_depth_at_entry, node.line)
      @chunk.emit(Op::Jump, node.line, c: @loop_stack.last.body_pos.to_u32)
    end

    private def compile_yield(node : YieldNode) : Nil
      node.args.each { |arg| compile_node(arg) }
      @chunk.emit(Op::Yield, node.line, a: node.args.size.to_u8)
    end

    private def compile_super(node : SuperNode) : Nil
      # STEP 3 of the super-dispatch rewrite (see SCOPE.md): bare
      # `super` (`node.forwarded?` — real Ruby's "zsuper") now
      # forwards the enclosing method's CURRENT parameter values,
      # rather than compiling as a fake zero-arg call (Step 1's
      # temporary shape). No args are compiled/pushed for this form
      # at all — dispatch_super reads them straight off the running
      # frame's locals at the point `super` executes, so a param
      # reassigned earlier in the method body is correctly forwarded
      # with its NEW value, matching Ruby.
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

      # Only node.body itself is lexically "inside" this construct's
      # handler region — the rescue/ensure clauses below run AFTER
      # the handler entry they belong to is being torn down (EndTry/
      # EnterEnsure), not while it's still the nearest enclosing one.
      # A break/next inside the rescue or ensure body itself is
      # already past this construct, not skipping over it, so it
      # must not see this region on @ensure_stack either — hence the
      # narrow push/pop bracketing only compile_body(node.body).
      @ensure_stack.push(EnsureRegion.new(node.ensure_body))
      compile_body(node.body)
      @ensure_stack.pop
      @chunk.emit(Op::EndTry, node.line) if has_rescue

      # `else` only runs on the success path (body raised nothing) —
      # by this point Op::EndTry has already cleared this construct's
      # rescue protection, so an error raised inside `else_body` is
      # correctly NOT caught by this begin's own rescue clauses,
      # matching real Ruby exactly. `else`'s value replaces the
      # body's as the overall expression's result when present, so
      # the body's leftover value is discarded first.
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
        # Discard the ensure block's own trailing value — the overall
        # begin/ensure expression's value is the body's (or rescue's),
        # not the ensure block's. compile_body always leaves exactly
        # one value on the stack, so this Pop is always safe.
        @chunk.emit(Op::Pop, node.line)
        # If this ensure was entered while an error was propagating
        # (not the normal success path), resume propagating it now
        # that the ensure body has finished. No-op otherwise.
        @chunk.emit(Op::EndEnsure, node.line)
      end
    end

    # Emits Op::Try (if has_rescue) and Op::SetEnsure (if an ensure
    # body exists), returning their patchable indices. Split out of
    # compile_begin purely to keep its cyclomatic complexity down.
    #
    # Op::Try's jump target only ever gets patched inside
    # compile_rescue_clause. An ensure-only begin (no rescue) has no
    # such patch site, so emitting Try here would push an unpatched
    # NO_TARGET sentinel onto Frame#handlers — reading it via
    # UInt32#to_i is a checked conversion that raises OverflowError
    # the moment Try executes, since NO_TARGET doesn't fit in Int32.
    # An ensure-only block doesn't catch anything anyway, so it has
    # no need for Try/EndTry at all.
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

    # Chains every `rescue` clause in source order — the first whose
    # class list matches the raised error wins, same as real Ruby
    # (no "most specific first" reordering; clauses are just tried
    # top to bottom). A clause with multiple classes (`rescue A, B`)
    # OR's them together, left-to-right, short-circuiting on the
    # first match. If no clause matches, the original error
    # propagates via Reraise, same as the single-clause case before.
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

      # Fell through every clause with no match — keep the error's
      # original identity (class, message) alive as it propagates
      # further out, rather than rebuilding a generic one via
      # Op::Throw.
      @chunk.emit(Op::PushError, node.line)
      @chunk.emit(Op::Reraise, node.line)

      match_done_jumps.each { |j| @chunk.patch_jump(j, @chunk.pos) }
      @chunk.patch_jump(jmp_past_rescue, @chunk.pos)
    end

    # Emits the is_a?-OR test for one clause's class list and returns
    # the jump to take on no match (falls through to whatever comes
    # next — the clause's caller patches it to either the next
    # clause's test or the final Reraise).
    private def compile_rescue_clause_test(node : BeginNode, clause : RescueClause) : Int32
      # Ruby's bare `rescue` (no explicit class) only catches
      # StandardError and below — fatal Exception-only errors still
      # propagate. Defaulting here reuses the exact same is_a? check
      # as an explicit filter, rather than duplicating an unfiltered
      # "catch everything" path.
      classes = clause.classes.empty? ? [Constant.new("StandardError", node.line, node.column)] of Node : clause.classes

      match_jumps = [] of Int32
      no_match_jump = 0
      classes.each_with_index do |cls, i|
        @chunk.emit(Op::PushError, node.line)
        compile_node(cls)
        # Call is_a?(error, rescue_class) using the same calling
        # convention as `error.is_a?(rescue_class)`.
        nil_idx = @chunk.add_const(Value.nil_value)
        @chunk.emit(Op::Const, node.line, c: nil_idx)
        @chunk.emit(Op::SetBlock, node.line)
        is_a_sym = intern("is_a?")
        @chunk.emit(Op::Call, node.line, a: 2_u8, b: 0b10_u16, c: is_a_sym)
        if i == classes.size - 1
          # Last (or only) class in this clause — false here means
          # the whole clause missed.
          no_match_jump = @chunk.emit_jump(Op::JumpIfFalse, node.line)
        else
          # Not the last — a match short-circuits straight to the
          # clause body; a miss falls through to try the next class.
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
      # `begin...end while cond` / `begin...end until cond` — the
      # do-while form, where the wrapped expression happens to be
      # a `begin` block — is a deliberate scope decision (see
      # UNSUPPORTED.md, U016), not merely unimplemented: real Ruby
      # gives this ONE specific form different semantics than
      # every other modifier-while (runs its body once before the
      # first condition check, rather than checking first like
      # `expr while cond` always does otherwise) — a single AST shape
      # (ModifierWhile wrapping a BeginNode) silently switching what
      # the rest of this method means undermines exactly the kind of
      # local, read-the-code-and-know-what-it-does reasoning this
      # subset exists to preserve. Rejected HERE for the ASSIGNED
      # form specifically (`x = begin...end while cond` and its
      # `+=`/`-=`/`*=`/`/=`/`%=`/`||=`/`&&=` siblings — the only ways
      # this construct successfully parses into a ModifierWhile at
      # all): this is the one point that already knows precisely which
      # form it is, once parsing has finished building the node.
      # The far more natural BARE-statement form (`begin...end
      # while cond` on its own, no assignment) never reaches this
      # method or builds a ModifierWhile in the first place — see
      # `Parser#reject_do_while` (`parser.cr`) for that one, an earlier
      # rejection at the point parse_statement's `KwBegin` case sees a
      # `while`/`until` immediately follow a bare `begin...end`, since
      # nothing downstream of THAT gap would ever have produced a node
      # for this method to check to begin with.
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

      # Real Ruby gives `expr while cond` (this method's only
      # remaining job now that the do-while form above is
      # rejected) CHECK-FIRST semantics, identical in shape to a plain
      # `while`/`until` statement, just written postfix — `x -= 1
      # while x > 0` may run zero times, the same as `while x > 0; x
      # -= 1; end` would. Found 2026-08-05: this method previously
      # compiled EVERY ModifierWhile — this form and the do-while form
      # alike — with check-LAST semantics (body always runs at least
      # once, condition checked only after) regardless of which one it
      # actually was. Correct only for the do-while form, silently
      # wrong for this one: `x -= 1 while x > 0` decremented x once
      # even when the condition was false from the very first check.
      # No test anywhere caught this, for either form, before this
      # session.
      raise loop_too_deep(node) if @loop_stack.size >= MAX_LOOP_DEPTH
      loop_start = @chunk.pos
      scope = LoopScope.new(loop_start, ensure_depth_at_entry: @ensure_stack.size)
      @loop_stack.push(scope)

      compile_node(node.cond)
      @chunk.emit(Op::Not, node.line) if node.until_loop?
      jmp_exit = @chunk.emit_jump(Op::JumpIfFalse, node.line)
      # Struct-copy trap: @loop_stack[-1] = ... (read-modify-write
      # through the array INDEX), not `.last.body_pos = ...` or
      # mutating the local `scope` after it was already pushed — see
      # compile_while's identical fix (same file) for the full
      # mechanism; LoopScope is a struct, so either of those silently
      # writes to a copy the array never sees.
      current = @loop_stack[-1]
      current.body_pos = @chunk.pos
      @loop_stack[-1] = current

      compile_node(node.body)
      @chunk.emit(Op::Pop, node.line)
      @chunk.emit(Op::Jump, node.line, c: loop_start.to_u32)
      @chunk.patch_jump(jmp_exit, @chunk.pos)

      # Fallthrough (condition went false, no break) has nothing on
      # the stack yet for this expression's value — push nil, same as
      # an unbroken while/until always evaluates to. A break already
      # pushed its OWN value before jumping (compile_break); landing
      # on this same emit_nil and falling through it would push a
      # second, spurious nil on top of that value — see compile_while
      # for the identical reasoning and the test that originally
      # caught it. So breaks patch to AFTER emit_nil, not onto it.
      emit_nil(node.line)
      tail = @chunk.pos

      scope = @loop_stack.pop
      scope.breaks.each { |brk| @chunk.patch_jump(brk, tail) }
    end

    # Finds the BeginNode that makes a ModifierWhile's body a do-while,
    # if any — either the body IS one directly, or it's exactly one
    # layer of assignment away from one (`x = begin...end while cond`
    # and its `+=`/`-=`/`*=`/`/=`/`%=`/`||=`/`&&=` siblings — Assign,
    # OpAssign, and CondAssign all share a `value` field for their
    # RHS, which is what maybe_assignment actually built the
    # ModifierWhile around, not the BeginNode itself). In practice
    # only the assignment-wrapped shapes are ever actually reachable
    # here — `Parser#reject_do_while` (parser.cr) catches the bare,
    # unwrapped `begin...end while cond` statement at parse time,
    # before any ModifierWhile is built for it at all — but the direct
    # BeginNode case stays here as a defensive fallback rather than an
    # assumption baked in twice (both places would need to agree for
    # dropping it to be safe, and only one of them needs to be right
    # for keeping it to be). Returns nil for every other shape,
    # including a BeginNode buried deeper than one assignment layer
    # down (e.g. inside a method call's argument) — real Ruby's
    # do-while trigger is specifically "the modifier's immediate
    # operand, largely ignoring assignment, is a begin block," not "a
    # begin block appears anywhere in the expression."
    private def do_while_begin(node : Node) : BeginNode?
      case node
      when BeginNode  then node
      when Assign     then node.value.as?(BeginNode)
      when OpAssign   then node.value.as?(BeginNode)
      when CondAssign then node.value.as?(BeginNode)
      else                 nil
      end
    end

    # --- Helpers ------------------------------------------------------------

    private def intern(name : String) : UInt32
      sym = @symbols.intern(name)
      @chunk.add_const(Value.symbol(sym))
    end
  end
end
