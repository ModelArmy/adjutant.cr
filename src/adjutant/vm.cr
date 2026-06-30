require "./bytecode"
require "./symbol_table"
require "./value"

module Adjutant
  # A compiled proc (method body or block).
  # Can be stored as a Value in the constant pool
  # and passed as a first-class script value.
  class ScriptProc
    getter chunk : Chunk
    getter name : String
    getter params : Array(String)
    getter local_count : Int32
    getter? is_block : Bool

    def initialize(@chunk, @name, @params = [] of String, @local_count = 0, @is_block = false)
    end
  end

  # A single call frame on the VM stack.
  class Frame
    getter proc : ScriptProc
    getter chunk : Chunk
    property ip : Int32
    property line : Int32
    property stack_base : Int32
    getter filename : String
    property block : ScriptProc?
    property rescue_ip : Int32
    property ensure_ip : Int32

    # Local variable slots — sized from ScriptProc#local_count at frame creation.
    getter locals : Array(Value)

    # Captured locals from the enclosing frame (for block closures).
    # nil for method frames; set to the enclosing frame's locals for blocks.
    property outer_locals : Array(Value)?

    def initialize(@proc, @chunk, @stack_base, @filename, @block = nil, outer : Array(Value)? = nil)
      @ip = 0
      @line = 0
      @rescue_ip = 0
      @ensure_ip = 0
      @locals = Array(Value).new(@proc.local_count, Value.nil_value)
      @outer_locals = outer
    end
  end

  # Execution limits — zero means unlimited.
  struct ExecutionLimits
    property instruction_limit : UInt64
    property call_depth_limit : Int32

    def initialize(
      @instruction_limit = 0_u64,
      @call_depth_limit = 256,
    )
    end
  end

  # RuntimeError raised when a script throws or hits a limit.
  class RuntimeError < Exception
    getter line : Int32
    getter filename : String

    def initialize(message : String, @filename = "<script>", @line = 0, cause = nil)
      super(message, cause)
    end

    def initialize(message : String, frame : Frame, cause = nil)
      @filename = frame.filename
      @line = frame.line
      super(message, cause)
    end
  end

  # The bytecode VM.
  #
  # One VM instance per script execution. Holds the value stack,
  # call frame stack, globals, and execution state.
  class VM
    MAX_STACK = 4096

    getter instruction_count : UInt64
    getter globals : Hash(Int32, Value)

    def initialize(
      @symbols : SymbolTable,
      @limits : ExecutionLimits = ExecutionLimits.new,
      @effect : EffectHandler? = nil,
      @interpreter : Interpreter? = nil,
      @globals : Hash(Int32, Value) = {} of Int32 => Value,
    )
      @stack = Array(Value).new(256)
      @frames = [] of Frame
      @instruction_count = 0_u64
      @current_block = nil.as(ScriptProc?)
      @current_self = Value.nil_value
    end

    # Execute a compiled chunk and return the result.
    def run(chunk : Chunk, filename : String = "<script>") : Value
      raise RuntimeError.new("Must be fresh VM to run a compiled chunk.", filename) unless @frames.empty?
      main_proc = ScriptProc.new(chunk, "<main>")
      push_frame(main_proc, filename)
      execute
    end

    # Execute a compiled script proc and return the result.
    # Can be called from within an execution via a native function.
    protected def invoke(proc : ScriptProc, args : Array(Value)) : Value
      saved_frames = @frames
      saved_ins_count = @instruction_count
      saved_cur_block = @current_block
      saved_cur_self = @current_self
      result = Value.nil_value
      begin
        f = current_frame # before replacing @frames
        @frames = [] of Frame
        # Setup the proc call, and ...
        call_script_proc(proc, args, f.filename, nil, f.locals)
        # Let the VM execute the chunk
        result = execute
      ensure
        @frames = saved_frames
        @instruction_count = saved_ins_count
        @current_block = saved_cur_block
        @current_self = saved_cur_self
      end
      result
    end

    # Register a global variable by name.
    def set_global(name : String, value : Value) : Nil
      sym = @symbols.intern(name)
      @globals[sym.value] = value
    end

    private def push_frame(proc : ScriptProc, filename : String, block : ScriptProc? = nil, stack_base : Int32 = @stack.size, outer : Array(Value)? = nil) : Frame
      if @limits.call_depth_limit > 0 && @frames.size >= @limits.call_depth_limit
        raise runtime_error("call stack too deep (limit: #{@limits.call_depth_limit})")
      end
      frame = Frame.new(proc, proc.chunk, stack_base, filename, block, outer)
      @frames.push(frame)
      frame
    end

    private def pop_frame : Frame
      @frames.pop
    end

    private def current_frame : Frame
      @frames.last
    end

    private def push(v : Value) : Nil
      raise runtime_error("stack overflow") if @stack.size >= MAX_STACK
      @stack.push(v)
    end

    private def pop : Value
      raise runtime_error("stack underflow") if @stack.size <= current_frame.stack_base
      @stack.pop
    end

    private def peek : Value
      @stack.last
    end

    private def tick : Nil
      @instruction_count += 1
      if @limits.instruction_limit > 0 && @instruction_count > @limits.instruction_limit
        raise runtime_error("instruction limit exceeded (#{@limits.instruction_limit})")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def execute : Value
      result = Value.nil_value

      loop do
        break if @frames.empty?
        f = current_frame
        chunk = f.chunk

        break if f.ip >= chunk.code.size

        inst = chunk.code[f.ip]
        f.ip += 1
        f.line = inst.line
        tick

        case inst.op
        when Op::Noop
          # nothing

        when Op::Const
          push(chunk.consts[inst.c])
        when Op::Pop
          @stack.pop if @stack.size > f.stack_base
        when Op::Dup
          push(peek)
          # --- Globals --------------------------------------------------------

        when Op::GetGlobal
          sym = chunk.consts[inst.c].as_sym
          push(@globals[sym.value]? || Value.nil_value)
        when Op::SetGlobal
          sym = chunk.consts[inst.c].as_sym
          val = pop
          @globals[sym.value] = val
          push(val)

          # --- Instance / class variables ------------------------------------
          # For now stored in globals with mangled names; a full object model
          # will route these through the current self in a later phase.

        when Op::GetIvar
          sym = chunk.consts[inst.c].as_sym
          push(@globals[sym.value]? || Value.nil_value)
        when Op::SetIvar
          sym = chunk.consts[inst.c].as_sym
          val = pop
          @globals[sym.value] = val
          push(val)
        when Op::GetCvar
          sym = chunk.consts[inst.c].as_sym
          push(@globals[sym.value]? || Value.nil_value)
        when Op::SetCvar
          sym = chunk.consts[inst.c].as_sym
          val = pop
          @globals[sym.value] = val
          push(val)

          # --- Stack ops ------------------------------------------------------
        when Op::GetIndex
          idx = pop
          target = pop
          push(exec_get_index(target, idx, safe: false))
        when Op::SafeIndex
          idx = pop
          target = pop
          push(exec_get_index(target, idx, safe: true))
        when Op::SetIndex
          val = pop
          idx = pop
          target = pop
          exec_set_index(target, idx, val)
          push(val)

          # --- Calls ----------------------------------------------------------
        when Op::SetBlock
          v = pop
          @current_block = v.proc? ? v.as_proc.as(ScriptProc) : nil
        when Op::Call, Op::SafeCall
          sym = chunk.consts[inst.c].as_sym
          argc = inst.a.to_i
          safe = inst.b != 0

          args = @stack.last(argc)
          @stack.pop(argc) if argc > 0

          depth_before = @frames.size
          result = dispatch_call(sym.name, args, safe, f.filename, inst.line, @current_block)
          @current_block = nil
          # If dispatch pushed a new ScriptProc frame, do NOT push the
          # sentinel return value — Op::Ret will push the real result.
          push(result) if @frames.size == depth_before
        when Op::Ret
          result = pop
          # Drain locals back to stack_base
          f.stack_base.upto(@stack.size - 1) { @stack.pop } if @stack.size > f.stack_base
          pop_frame
          push(result) unless @frames.empty?

          # --- Arithmetic -----------------------------------------------------
        when Op::Add    then exec_binary(inst) { |lhs, rhs| arith_add(lhs, rhs) }
        when Op::Sub    then exec_binary(inst) { |lhs, rhs| arith_op(lhs, rhs, :-) }
        when Op::Mul    then exec_binary(inst) { |lhs, rhs| arith_op(lhs, rhs, :*) }
        when Op::Div    then exec_binary(inst) { |lhs, rhs| arith_div(lhs, rhs) }
        when Op::Mod    then exec_binary(inst) { |lhs, rhs| arith_mod(lhs, rhs) }
        when Op::BitAnd then exec_binary(inst) { |lhs, rhs| int_op(lhs, rhs, :&) }
        when Op::BitOr  then exec_binary(inst) { |lhs, rhs| int_op(lhs, rhs, :|) }
        when Op::Xor    then exec_binary(inst) { |lhs, rhs| int_op(lhs, rhs, :^) }
        when Op::Shl    then exec_binary(inst) { |lhs, rhs| int_op(lhs, rhs, :<<) }
        when Op::Shr    then exec_binary(inst) { |lhs, rhs| int_op(lhs, rhs, :>>) }
          # --- Comparison -----------------------------------------------------

        when Op::Eq
          b, a = pop, pop
          push(Value.bool(values_equal?(a, b)))
        when Op::Lt  then exec_binary(inst) { |lhs, rhs| compare_op(lhs, rhs, :<) }
        when Op::Lte then exec_binary(inst) { |lhs, rhs| compare_op(lhs, rhs, :<=) }
        when Op::Gt  then exec_binary(inst) { |lhs, rhs| compare_op(lhs, rhs, :>) }
        when Op::Gte then exec_binary(inst) { |lhs, rhs| compare_op(lhs, rhs, :>=) }
          # --- Unary ----------------------------------------------------------

        when Op::Not
          push(Value.bool(pop.falsy?))
        when Op::Neg
          v = pop
          case
          when v.int?   then push(Value.int(-v.as_int))
          when v.float? then push(Value.float(-v.as_float))
          else               raise runtime_error("cannot negate #{v}", f)
          end
        when Op::BitNot
          v = pop
          raise runtime_error("~ requires Integer", f) unless v.int?
          push(Value.int(~v.as_int))

          # --- Jumps ----------------------------------------------------------
        when Op::Jump
          f.ip = inst.c.to_i
        when Op::JumpIfFalse
          v = pop
          f.ip = inst.c.to_i if v.falsy?
        when Op::JumpIfTrue
          v = pop
          f.ip = inst.c.to_i if v.truthy?

          # --- Collections ----------------------------------------------------
        when Op::MakeArray
          n = inst.a.to_i
          elements = @stack.last(n).dup
          @stack.pop(n) if n > 0
          push(Value.new(elements, nil))
        when Op::MakeHash
          n = inst.a.to_i * 2
          pairs = @stack.last(n)
          @stack.pop(n) if n > 0
          h = {} of Value => Value
          pairs.each_slice(2) { |pair| h[pair[0]] = pair[1] }
          push(Value.new(h, nil))
        when Op::MakeRange
          rend = pop
          rstart = pop
          # Store as array [start, end, exclusive_flag] for now;
          # a Range object type will be added with the object model.
          exclusive = inst.a == 1_u8
          elems = [rstart, rend, Value.bool(exclusive)]
          push(Value.new(elems, nil))
        when Op::Concat
          n = inst.a.to_i
          parts = @stack.last(n)
          @stack.pop(n) if n > 0
          str = parts.map { |part|
            case
            when part.string? then part.as_string
            when part.int?    then part.as_int.to_s
            when part.float?  then part.as_float.to_s
            when part.bool?   then part.as_bool.to_s
            when part.null?   then "nil"
            when part.symbol? then part.as_sym.name
            else                   part.to_s
            end
          }.join
          push(Value.string(str))

          # --- Local variables ------------------------------------------------
        when Op::GetLocal
          slot = inst.c.to_i
          push(slot < f.locals.size ? f.locals[slot] : Value.nil_value)
        when Op::SetLocal
          val = pop
          slot = inst.c.to_i
          if slot < f.locals.size
            f.locals[slot] = val
          else
            f.locals << val
          end
          push(val)
        when Op::GetOuter
          slot = inst.c.to_i
          outer = f.outer_locals
          push(outer && slot < outer.size ? outer[slot] : Value.nil_value)
        when Op::SetOuter
          val = pop
          slot = inst.c.to_i
          outer = f.outer_locals
          outer[slot] = val if outer && slot < outer.size
          push(val)
        when Op::MakeProc
          push(chunk.consts[inst.c])
          # --- Class / module (stubs) ----------------------------------------
        when Op::GetClass
          push(@current_self) # simplified until object model lands

        when Op::SetClass
          @current_self = pop
        when Op::MakeClass, Op::MakeModule
          name_sym = chunk.consts[inst.c].as_sym
          push(Value.string("__class__:#{name_sym.name}"))
        when Op::DefMethod
          proc_val = pop
          name_sym = chunk.consts[inst.c].as_sym
          @globals[@symbols.intern(name_sym.name).value] = proc_val
          push(Value.nil_value)
        when Op::DefSingleton
          _recv = pop
          proc_val = pop
          name_sym = chunk.consts[inst.c].as_sym
          @globals[@symbols.intern(name_sym.name).value] = proc_val
          push(Value.nil_value)

          # --- Block / yield --------------------------------------------------
        when Op::Yield
          argc = inst.a.to_i
          args = @stack.last(argc)
          @stack.pop(argc) if argc > 0
          blk = f.block
          if blk
            depth_before = @frames.size
            result = call_script_proc(blk, args, f.filename, nil, f.locals)
            push(result) if @frames.size == depth_before
          else
            raise runtime_error("no block given", f)
          end
        when Op::BlockBreak
          val = pop
          # Unwind to the nearest non-block frame
          while !@frames.empty? && @frames.last.proc.is_block?
            sb = @frames.last.stack_base; (@stack.size - sb).times { @stack.pop } if @stack.size > sb
            pop_frame
          end
          push(val)

          # --- Exception handling (stubs) ------------------------------------
        when Op::Try
          f.rescue_ip = inst.c.to_i
        when Op::SetEnsure
          f.ensure_ip = inst.c.to_i
        when Op::EndTry
          f.rescue_ip = 0
        when Op::EnterEnsure
          # ensure body follows inline

        when Op::Throw
          val = pop
          msg = val.string? ? val.as_string : val.to_s
          raise runtime_error(msg, f)
        when Op::PushError
          # Push the last error as a string value — stub until typed exceptions land
          push(Value.string("RuntimeError"))
        when Op::Retry
          # Jump back to start of begin body — stub
          f.ip = 0
          # --- Misc -----------------------------------------------------------

        when Op::MultiUnpack
          tc = inst.a.to_i
          vc = inst.b.to_i
          values = @stack.last(vc)
          @stack.pop(vc) if vc > 0
          # Pad or truncate to target count
          padded = Array(Value).new(tc) { |i| i < values.size ? values[i] : Value.nil_value }
          padded.each { |value| push(value) }
        when Op::GetMethodName
          push(Value.string(f.proc.name))
        else
          raise runtime_error("unknown opcode: #{inst.op}", f)
        end
      end

      @stack.last? || result
    end

    # --- Dispatch -----------------------------------------------------------

    private def dispatch_call(name : String,
                              args : Array(Value),
                              safe : Bool,
                              filename : String, line : Int32,
                              blk : ScriptProc? = nil) : Value
      # Safe navigation: skip call if receiver (first arg) is nil
      if safe && !args.empty? && args.first.null?
        return Value.nil_value
      end

      # Check native functions registered via interpreter
      if interp = @interpreter
        sym_id = (@symbols.lookup(name).try(&.value)) || -1
        if native = interp.native_func(sym_id)
          result = Value.nil_value
          begin
            result = NativeFunctionCall.new(self, native, filename, line).call(args, blk)
          rescue ex
            # Wrap any exception
            raise runtime_error("Native call error: #{ex.message}", current_frame, cause: ex)
          end
          return result
        end
      end

      # Check globals for a ScriptProc
      sym = @symbols.lookup(name)
      if sym
        gval = @globals[sym.value]?
        if gval && gval.proc?
          sproc = gval.as_proc.as(ScriptProc)
          return call_script_proc(sproc, args, filename, blk, nil)
        end
      end

      # Built-in fallback operations
      exec_builtin(name, args, filename, line, blk)
    end

    # Call a ScriptProc, binding arguments to param slots and optionally
    # passing a block and outer locals for closure capture.
    # Does NOT call execute recursively — pushes the frame and returns a
    # sentinel. The outer execute loop continues with the new frame, and
    # Op::Ret restores the caller frame automatically.
    private def call_script_proc(proc : ScriptProc,
                                 args : Array(Value),
                                 filename : String,
                                 blk : ScriptProc? = nil,
                                 outer : Array(Value)? = nil) : Value
      base = @stack.size
      frame = push_frame(proc, filename, block: blk, stack_base: base, outer: outer)
      args.each_with_index do |arg, i|
        frame.locals[i] = arg if i < frame.locals.size
      end
      Value.nil_value # sentinel; Op::Ret will push the real return value
    end

    # Minimal built-ins needed for specs to pass before stdlib lands.
    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_builtin(name : String, args : Array(Value), filename : String, line : Int32, blk : ScriptProc? = nil) : Value
      case name
      when "puts"
        str = args.map { |arg|
          case
          when arg.string? then arg.as_string
          when arg.null?   then "nil"
          when arg.bool?   then arg.as_bool.to_s
          when arg.int?    then arg.as_int.to_s
          when arg.float?  then arg.as_float.to_s
          when arg.symbol? then arg.as_sym.to_s
          else                  arg.to_s
          end
        }.join("\n")
        if ef = @effect
          ef.write_stdout(str + "\n")
        else
          STDOUT.puts(str)
        end
        Value.nil_value
      when "print"
        str = args.map(&.to_s).join
        if ef = @effect
          ef.write_stdout(str)
        else
          STDOUT.print(str)
        end
        Value.nil_value
      when "p"
        str = args.map(&.inspect).join("\n")
        if ef = @effect
          ef.write_stdout(str + "\n")
        else
          STDOUT.puts(str)
        end
        args.size == 1 ? args.first : Value.new(args.dup, nil)
      when "raise"
        msg = args.first? ? args.first.to_s : "RuntimeError"
        raise RuntimeError.new(msg, filename, line)
      when "require"
        path = args.first? ? args.first.as_string : ""
        if interp = @interpreter
          interp.require_module(path, filename)
        else
          raise RuntimeError.new("'require' cannot load -- #{path} (no interpreter)", filename, line)
        end
      when "nil?"
        # Called as a method: args[0] is receiver
        recv = args.first? || Value.nil_value
        Value.bool(recv.null?)
      when "is_a?"
        Value.bool(false) # stub
      when "to_s"
        recv = args.first? || Value.nil_value
        Value.string(recv.to_s)
      when "to_i"
        recv = args.first? || Value.nil_value
        case
        when recv.int?    then recv
        when recv.float?  then Value.int(recv.as_float.to_i64)
        when recv.string? then Value.int(recv.as_string.to_i64? || 0_i64)
        else                   Value.int(0_i64)
        end
      when "to_f"
        recv = args.first? || Value.nil_value
        case
        when recv.float?  then recv
        when recv.int?    then Value.float(recv.as_int.to_f64)
        when recv.string? then Value.float(recv.as_string.to_f64? || 0.0)
        else                   Value.float(0.0)
        end
      when "length", "size"
        recv = args.first? || Value.nil_value
        case
        when recv.string? then Value.int(recv.as_string.size.to_i64)
        when recv.array?  then Value.int(recv.as_array.size.to_i64)
        when recv.hash?   then Value.int(recv.as_hash.size.to_i64)
        else                   Value.int(0_i64)
        end
      when "+"
        arith_add(args[0], args[1])
      when "-"
        arith_op(args[0], args[1], :-)
      when "*"
        arith_op(args[0], args[1], :*)
      when "/"
        arith_div(args[0], args[1])
      when "%"
        arith_mod(args[0], args[1])
      else
        Value.nil_value
      end
    end

    # --- Arithmetic helpers -------------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    private def arith_add(a : Value, b : Value) : Value
      case
      when a.int? && b.int?       then Value.int(a.as_int + b.as_int)
      when a.float? && b.float?   then Value.float(a.as_float + b.as_float)
      when a.int? && b.float?     then Value.float(a.as_int.to_f64 + b.as_float)
      when a.float? && b.int?     then Value.float(a.as_float + b.as_int.to_f64)
      when a.string? && b.string? then Value.string(a.as_string + b.as_string)
      else
        raise runtime_error("cannot add #{a} and #{b}")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def arith_op(a : Value, b : Value, op : Symbol) : Value
      case
      when a.int? && b.int?
        n = case op
            when :- then a.as_int - b.as_int
            when :* then a.as_int * b.as_int
            else         0_i64
            end
        Value.int(n)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        n = case op
            when :- then fa - fb
            when :* then fa * fb
            else         0.0
            end
        Value.float(n)
      else
        raise runtime_error("type error in arithmetic")
      end
    end

    private def arith_div(a : Value, b : Value) : Value
      case
      when a.int? && b.int?
        raise runtime_error("divided by 0") if b.as_int == 0
        Value.int(a.as_int // b.as_int)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        raise runtime_error("divided by 0") if fb == 0.0
        Value.float(fa / fb)
      else
        raise runtime_error("type error in division")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def arith_mod(a : Value, b : Value) : Value
      raise runtime_error("divided by 0") if (b.int? && b.as_int == 0) || (b.float? && b.as_float == 0.0)
      case
      when a.int? && b.int? then Value.int(a.as_int % b.as_int)
      when a.float? || b.float?
        fa = a.int? ? a.as_int.to_f64 : a.as_float
        fb = b.int? ? b.as_int.to_f64 : b.as_float
        Value.float(fa % fb)
      else
        raise runtime_error("type error in modulo")
      end
    end

    private def int_op(a : Value, b : Value, op : Symbol) : Value
      raise runtime_error("bitwise op requires Integer") unless a.int? && b.int?
      n = case op
          when :&  then a.as_int & b.as_int
          when :|  then a.as_int | b.as_int
          when :^  then a.as_int ^ b.as_int
          when :<< then a.as_int << b.as_int
          when :>> then a.as_int >> b.as_int
          else          0_i64
          end
      Value.int(n)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def compare_op(a : Value, b : Value, op : Symbol) : Value
      result = case
               when a.int? && b.int?
                 case op
                 when :<  then a.as_int < b.as_int
                 when :<= then a.as_int <= b.as_int
                 when :>  then a.as_int > b.as_int
                 when :>= then a.as_int >= b.as_int
                 else          false
                 end
               when a.float? || b.float?
                 fa = a.int? ? a.as_int.to_f64 : a.as_float
                 fb = b.int? ? b.as_int.to_f64 : b.as_float
                 case op
                 when :<  then fa < fb
                 when :<= then fa <= fb
                 when :>  then fa > fb
                 when :>= then fa >= fb
                 else          false
                 end
               when a.string? && b.string?
                 case op
                 when :<  then a.as_string < b.as_string
                 when :<= then a.as_string <= b.as_string
                 when :>  then a.as_string > b.as_string
                 when :>= then a.as_string >= b.as_string
                 else          false
                 end
               else
                 false
               end
      Value.bool(result)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def values_equal?(a : Value, b : Value) : Bool
      case
      when a.null? && b.null?     then true
      when a.bool? && b.bool?     then a.as_bool == b.as_bool
      when a.int? && b.int?       then a.as_int == b.as_int
      when a.float? && b.float?   then a.as_float == b.as_float
      when a.int? && b.float?     then a.as_int.to_f64 == b.as_float
      when a.float? && b.int?     then a.as_float == b.as_int.to_f64
      when a.string? && b.string? then a.as_string == b.as_string
      when a.symbol? && b.symbol? then a.as_sym == b.as_sym
      else                             false
      end
    end

    # --- Index helpers ------------------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    private def exec_get_index(target : Value, idx : Value, safe : Bool) : Value
      return Value.nil_value if safe && target.null?
      case
      when target.array? && idx.int?
        i = idx.as_int
        arr = target.as_array
        i = arr.size + i if i < 0
        (i >= 0 && i < arr.size) ? arr[i] : Value.nil_value
      when target.hash?
        target.as_hash[idx]? || Value.nil_value
      when target.string? && idx.int?
        i = idx.as_int.to_i
        s = target.as_string
        i = s.size + i if i < 0
        (i >= 0 && i < s.size) ? Value.string(s[i].to_s) : Value.nil_value
      else
        Value.nil_value
      end
    end

    private def exec_set_index(target : Value, idx : Value, val : Value) : Nil
      case
      when target.array? && idx.int?
        i = idx.as_int.to_i
        arr = target.as_array
        i = arr.size + i if i < 0
        arr[i] = val if i >= 0 && i < arr.size
      when target.hash?
        target.as_hash[idx] = val
      end
    end

    private def exec_binary(inst : Instruction, &block : Value, Value -> Value) : Nil
      b = pop
      a = pop
      push(block.call(a, b))
    end

    private def runtime_error(msg : String, frame : Frame = current_frame, cause = nil) : RuntimeError
      RuntimeError.new(msg, frame, cause)
    end
  end
end
