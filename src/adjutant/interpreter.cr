require "./symbol_table"
require "./lexer"
require "./parser"
require "./compiler"
require "./bytecode"
require "./module_registry"
require "./vm"
require "./effect_handler"
require "./risk_profile"
require "./risk_flow_policy"
require "./risk_flow_decision"
require "./native_callable"
require "./native_call_context"
require "./native_function_call"
require "./builtins"
require "./legate"

module Adjutant
  # The host's entry point. Owns the symbol table, the module registry,
  # the grants and the run's broker; builds a fresh VM for each `eval`.
  #
  # `risk_flow_policy` and `on_risk_flow_decision` are required: there
  # is no default that skips risk assessment. A host that wants none
  # passes `RiskFlowPolicy.reject_all`, and still supplies the callback,
  # so the constructor's shape doesn't depend on the policy's contents.
  # `grants` defaults to `Grants.deny_all`.
  #
  # Usage:
  #   effect  = TestEffectHandler.new
  #   interp  = Interpreter.new(
  #     effect: effect,
  #     risk_flow_policy: RiskFlowPolicy.reject_all,
  #     on_risk_flow_decision: ->(req : RiskFlowDecisionRequest) { RiskFlowDecision::Reject },
  #   )
  #   interp.modules.register("agent/io") { |i| ... }
  #   interp.eval("require \"agent/io\"\nputs(42)")
  class Interpreter
    getter symbols : SymbolTable
    getter modules : ModuleRegistry
    getter effect : EffectHandler?
    getter limits : ExecutionLimits
    getter risk_flow_log : RiskFlowLog
    getter risk_flow_policy : RiskFlowPolicy
    getter on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision

    # Legate's grants, fixed at construction (LEGATE.md §7), and the
    # Legate broker every verb uses, so budget and audit state build up
    # across the run.
    getter grants : Legate::Grants
    getter broker : Legate::Broker

    # The `log:` argument has no getter; it is `broker.log`.

    # The run's shared authorization sequence, wrapped by `broker`.
    getter effect_broker : Adjutant::Broker

    # Source of every script this interpreter has parsed, keyed by
    # filename. Populated by `eval`/`compile`, including files pulled
    # in by `require`, whose diagnostics name a different file than
    # the top-level script.
    getter sources : SourceMap = SourceMap.new

    # Where a reader is told to report an internal (I-series) error.
    # A host should point this at its own support channel.
    property report_url : String = DiagnosticRenderer::DEFAULT_REPORT_URL

    # Top-level `self`, an Object, as Ruby's `main` is. A top-level
    # `def` becomes a method of Object. Shared by every `eval` on this
    # Interpreter, so top-level methods persist between them; top-level
    # local variables don't.
    getter main : RubyObject

    def initialize(
      @risk_flow_policy : RiskFlowPolicy,
      @on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision,
      @effect : EffectHandler? = nil,
      @limits : ExecutionLimits = ExecutionLimits.new,
      risk_flow_tracking : Bool = false,
      @grants : Legate::Grants = Legate::Grants.deny_all,
      log : ::Log = Legate::Broker::DEFAULT_LOG,
    )
      @symbols = SymbolTable.new
      @modules = ModuleRegistry.new
      @globals = {} of Int32 => Value
      @risk_flow_log = RiskFlowLog.new(enabled: risk_flow_tracking)
      # One broker per run, shared by every provider.
      @effect_broker = Adjutant::Broker.new(@grants.limits)
      @broker = Legate::Broker.new(@grants, @effect_broker, log: log)
      bootstrap_core_hierarchy
      # Assigned as soon as Object exists: Crystal requires every
      # non-nilable ivar set before `self` is passed anywhere, and the
      # bootstraps below pass it.
      @main = RubyObject.new(object_class)
      # Object's `to_s` and `inspect`, which every class inherits.
      Builtins.bootstrap_object_methods(self, object_class)
      bootstrap_builtin_classes
    end

    # Registers a built RubyClass as a global under its own name, where
    # a top-level `class Foo` would put it.
    def define_global_class(cls : RubyClass) : RubyClass
      sym = @symbols.intern(cls.name)
      @globals[sym.value] = Value.rclass(cls)
      cls
    end

    # The global `name`'s current value, or nil.
    def get_global(name : String) : Value
      sym = @symbols.lookup(name)
      return Value.nil_value unless sym
      @globals[sym.value]? || Value.nil_value
    end

    # Parses a script without compiling or running it, for a host
    # that walks the AST for risk before deciding to run it. Registers
    # the source first, so any later diagnostic can quote it; a host
    # using `Parser` directly gets diagnostics without snippets.
    def parse(source : String, filename : String = "<parse>") : Body
      parse(IO::Memory.new(source), filename)
    end

    # `parse` from an IO.
    def parse(io : IO, filename : String = "<parse>") : Body
      parser = Parser.new(io, filename)
      # Registered before parsing, so a ParseError gets a snippet too.
      sources.register(filename, parser.source)
      parser.parse
    end

    # Parses, compiles and runs a source string.
    def eval(source : String, filename : String = "<eval>") : Value
      eval(IO::Memory.new(source), filename)
    end

    # Parses, compiles and runs from an IO.
    def eval(io : IO, filename : String = "<eval>") : Value
      eval(parse(io, filename), filename)
    end

    # Compiles and runs an already-parsed script: the body that was
    # assessed runs, with no second parse. Pass the filename given to
    # `parse`; a Body doesn't record it, and a different name loses the
    # source snippets.
    def eval(body : Body, filename : String) : Value
      chunk, local_count = Compiler.compile(body, @symbols)
      vm = make_vm
      begin
        vm.run(chunk, filename, local_count)
      ensure
        # Closes every stream source still open, after a normal return
        # or an exception, so the next script on this Interpreter starts
        # clean; the host process outlives the script. Failures are
        # collected, not raised, so they can't replace the script's own
        # error. Nothing reads the returned failures yet.
        @effect_broker.open_sources.close_all

        # Removes `Legate.scratch`'s directory, if one was created,
        # collecting failures as above.
        @broker.cleanup_scratch!
      end
    end

    # Compiles a source string without running it.
    def compile(source : String, filename : String = "<compile>") : Chunk
      compile(IO::Memory.new(source), filename)
    end

    def compile(io : IO, filename : String = "<compile>") : Chunk
      chunk, _local_count = Compiler.compile(parse(io, filename), @symbols)
      chunk
    end

    # Renders an error with its source line and carets. Nil for an
    # error the script raised itself, which has no diagnostic; show
    # its `message` instead.
    def render_error(error : ParseError | CompileError | RuntimeError |
                             HostArgumentError | HostStateError | InternalError |
                             AmbiguousRiskFlowPolicyError,
                     format : DiagnosticRenderer::Format = DiagnosticRenderer::Format::Markdown,
                     filename : String? = nil) : String?
      diag = error.diagnostic
      return unless diag
      DiagnosticRenderer.new(sources, report_url).render(diag, format, filename)
    end

    # Resolves `require "path"`: a registered module first, then a
    # source file through the EffectHandler.
    def require_module(path : String, filename : String) : Value
      return Value.bool(true) if @modules.require(path, self)

      if ef = @effect
        if src = ef.vfs_read(path)
          eval(IO::Memory.new(src), path)
          return Value.bool(true)
        end
      end

      raise RuntimeError.new(
        Diagnostic.new(
          code: "R010",
          primary: Span.new(line: 0, filename: filename),
          data: {"path" => path}
        ),
        filename,
        0
      )
    end

    # Installs a native function callable from anywhere by implicit
    # self: a native method of Object, as Ruby's Kernel methods are.
    # The block receives the arguments, the block if any, and a
    # NativeCallContext. `risk` defaults to none; pass a profile for any
    # function with external effects. `kwarg_names` lists the keywords
    # it accepts, read through `ncc.kwargs`. `is_private` makes it
    # callable only without a receiver.
    def define_native(name : String, risk : RiskProfile = RiskProfile.none, kwarg_names : Set(String) = Set(String).new, is_private : Bool = false,
                      authorities : Set(Authority) = Set(Authority).new,
                      &block : Array(Value), ScriptProc?, NativeCallContext -> Value) : Nil
      sym = @symbols.intern(name)
      object_class.define_native_method(sym.value, risk, kwarg_names, is_private: is_private,
        authorities: authorities, &block)
    end

    # The native function registered under `sym_id`, from Object's
    # native methods.
    def native_callable(sym_id : Int32) : NativeCallable?
      object_class.native_methods[sym_id]?
    end

    # The builtin class of a non-object Value (Integer for an Integer,
    # TrueClass or FalseClass for a Bool), for `is_a?`, `class` and
    # `respond_to?`. Nil for a kind with no class.
    def builtin_class_for(val : Value) : RubyClass?
      name = case
             when val.null?   then "NilClass"
             when val.bool?   then val.as_bool ? "TrueClass" : "FalseClass"
             when val.int?    then "Integer"
             when val.float?  then "Float"
             when val.string? then "String"
             when val.array?  then "Array"
             when val.hash?   then "Hash"
             when val.symbol? then "Symbol"
             else                  return
             end
      sym = @symbols.lookup(name)
      return unless sym
      @globals[sym.value]?.try(&.as_rclass?)
    end

    # The three core classes, looked up by name each time.
    def object_class : RubyClass
      @globals[@symbols.intern("Object").value].as_rclass
    end

    def class_class : RubyClass
      @globals[@symbols.intern("Class").value].as_rclass
    end

    def module_class : RubyClass
      @globals[@symbols.intern("Module").value].as_rclass
    end

    # A registered builtin class by name, or nil if none is
    # registered, as when bootstrap hasn't reached it.
    def find_builtin_class(name : String) : RubyClass?
      sym = @symbols.lookup(name)
      return unless sym
      @globals[sym.value]?.try(&.as_rclass?)
    end

    private def make_vm : VM
      VM.new(@symbols, @limits, @effect, self, @globals, @risk_flow_log, @risk_flow_policy, @on_risk_flow_decision)
    end

    # Builds Object, Class and Module, whose links are circular
    # (Object's class is Class, Class's superclass is Module, Class's
    # class is Class), by allocating all three and then linking them,
    # as CRuby does. Class and Module are uninstantiable (U002).
    private def bootstrap_core_hierarchy : Nil
      mod_cls = RubyClass.new("Module", nil, is_module: false, uninstantiable: true)
      class_cls = RubyClass.new("Class", nil, is_module: false, uninstantiable: true)
      obj_cls = RubyClass.new("Object", nil, is_module: false)

      # Class < Module < Object. There is no BasicObject, so
      # Object's superclass is nil. Module's link lets a module body
      # find Object's methods (such as `puts`) through its class.
      class_cls.superclass = mod_cls
      mod_cls.superclass = obj_cls
      obj_cls.rclass = class_cls
      class_cls.rclass = class_cls
      mod_cls.rclass = class_cls

      define_global_class(mod_cls)
      define_global_class(class_cls)
      define_global_class(obj_cls)
    end

    # Registers the exception hierarchy as globals, so `raise
    # SomeError` and `rescue SomeError` resolve. Once per Interpreter.
    private def bootstrap_error_classes : Nil
      standard_error = nil
      Builtins.bootstrap_exception_and_subclasses(self) do |cls|
        standard_error = cls if cls.name == "StandardError"
        register_builtin_class(cls)
      end
      unless standard_error
        raise InternalError.new("StandardError not bootstrapped before Legate::Exceptions.bootstrap ran")
      end
      bootstrap_legate(standard_error)
    end

    # Builds the `Legate` module once and nests every Legate class in
    # it: the exception tier first, then the value types. Registered
    # with `define_global_class`, since `register_builtin_class` would
    # give a module a superclass.
    private def bootstrap_legate(standard_error : RubyClass) : Nil
      legate = Legate::Helpers.build_module(self)
      Legate::Exceptions.bootstrap(self, legate, standard_error)
      Legate::Path.bootstrap(self, legate)
      Legate::Stat.bootstrap(self, legate)
      Legate::Entry.bootstrap(self, legate)
      Legate::Match.bootstrap(self, legate)
      Legate::Response.bootstrap(self, legate)
      Legate::Chunk.bootstrap(self, legate)
      Legate::Stream.bootstrap(self, legate)
      Legate::Verbs::Stat.bootstrap(self, legate, @broker)
      Legate::Verbs::Read.bootstrap(self, legate, @broker)
      Legate::Verbs::List.bootstrap(self, legate, @broker)
      Legate::Verbs::Bytes.bootstrap(self, legate, @broker)
      Legate::Verbs::Lines.bootstrap(self, legate, @broker)
      Legate::Verbs::Records.bootstrap(self, legate, @broker)
      Legate::Verbs::Grep.bootstrap(self, legate, @broker)
      Legate::Verbs::Write.bootstrap(self, legate, @broker)
      Legate::Verbs::Append.bootstrap(self, legate, @broker)
      Legate::Verbs::Mkdir.bootstrap(self, legate, @broker)
      Legate::Verbs::Cp.bootstrap(self, legate, @broker)
      Legate::Verbs::Rm.bootstrap(self, legate, @broker)
      Legate::Verbs::Mv.bootstrap(self, legate, @broker)
      Legate::Verbs::Fetch.bootstrap(self, legate, @broker)
      Legate::Verbs::Scratch.bootstrap(self, legate, @broker)
      Legate::Verbs::Log.bootstrap(self, legate, @broker)
      Legate::Verbs::Fail.bootstrap(self, legate, @broker)
      Legate::Verbs::Env.bootstrap(self, legate, @broker)
      Legate::Verbs::Now.bootstrap(self, legate, @broker)
      Legate::Verbs::Random.bootstrap(self, legate, @broker)
      define_global_class(legate)
    end

    # Registers every builtin class as a global. The `Builtins`
    # bootstraps build their RubyClass directly, so
    # `register_builtin_class` supplies the superclass and class.
    private def bootstrap_builtin_classes : Nil
      bootstrap_error_classes
      register_builtin_class(Builtins.bootstrap_integer(self))
      register_builtin_class(Builtins.bootstrap_float(self))
      register_builtin_class(Builtins.bootstrap_nil_class(self))
      register_builtin_class(Builtins.bootstrap_true_class(self))
      register_builtin_class(Builtins.bootstrap_false_class(self))
      register_builtin_class(Builtins.bootstrap_symbol(self))
      register_builtin_class(Builtins.bootstrap_string(self))
      register_builtin_class(Builtins.bootstrap_array(self))
      register_builtin_class(Builtins.bootstrap_hash(self))
      register_builtin_class(Builtins.bootstrap_range(self))
      register_builtin_class(Builtins.bootstrap_regexp(self))
      register_builtin_class(Builtins.bootstrap_match_data(self))
      register_builtin_class(Builtins.bootstrap_proc(self))
      register_builtin_class(Builtins.bootstrap_time(self))
      Builtins.register_module_methods(module_class, self)
    end

    # Defaults `cls`'s superclass to Object (if unset) and its class to
    # Class, then registers it.
    private def register_builtin_class(cls : RubyClass) : RubyClass
      cls.superclass ||= object_class
      cls.rclass = class_class
      define_global_class(cls)
    end

    # A new builtin class: superclass Object unless given, class
    # Class.
    private def define_builtin_class(name : String, superclass : RubyClass? = nil) : RubyClass
      cls = RubyClass.new(name, superclass || object_class, is_module: false)
      cls.rclass = class_class
      define_global_class(cls)
    end

    @globals : Hash(Int32, Value) = {} of Int32 => Value
  end
end
