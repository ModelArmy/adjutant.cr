require "../spec_helper"

module Adjutant
  # Native keyword argument support (2026-08-09) — see SCOPE.md's
  # former "Native methods have no way to declare or receive kwargs"
  # entry and DEVELOPMENT.md's "Native keyword arguments" note.
  #
  # Deliberately NOT modeled on Param/AST defaults (Compiler#
  # emit_default_prologue) — a native call has no compiled chunk to
  # run a default expression against. Instead: a NativeCallable
  # declares which keyword NAMES it accepts (kwarg_names); a native
  # function that wants a default value for an omitted key reads
  # NativeCallContext#kwargs itself and falls back in Crystal — the
  # same self-serve convention mruby's own `mrb_get_args` kwargs
  # binding uses (the C function pre-fills defaults; the binding
  # machinery only overwrites what the caller actually supplied), and
  # the same style testing/assert_module.cr's `assert` already uses
  # for positional presence checks.
  describe "native keyword arguments" do
    describe "a native function with no declared kwarg_names (the default)" do
      it "still rejects any supplied keyword with R012, same as before this session" do
        interp, _ = make_interp
        interp.define_native("greet") { |args| Value.string("hi") }
        error = expect_raises(RuntimeError) do
          interp.eval(%(greet(loudly: true)))
        end
        error.diagnostic.not_nil!.code.should eq("R012")
      end

      it "a call with no keywords at all still works normally" do
        interp, _ = make_interp
        interp.define_native("greet") { |args| Value.string("hi") }
        interp.eval(%(greet())).as_string.should eq "hi"
      end
    end

    describe "a native function that declares kwarg_names" do
      it "accepts a declared keyword and makes it readable via NativeCallContext#kwargs" do
        interp, _ = make_interp
        interp.define_native("configure", kwarg_names: Set{"timeout"}) do |args, blk, ncc|
          timeout = ncc.kwargs.try(&.["timeout"]?)
          timeout ? timeout : Value.nil_value
        end
        interp.eval(%(configure(timeout: 30))).as_int.should eq 30
      end

      it "rejects an undeclared keyword name with R012, naming the offending key" do
        interp, _ = make_interp
        interp.define_native("configure", kwarg_names: Set{"timeout"}) do |args, blk, ncc|
          Value.nil_value
        end
        error = expect_raises(RuntimeError) do
          interp.eval(%(configure(retries: 3)))
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("R012")
        diag.data["name"].should eq("retries")
      end

      it "an omitted declared keyword is simply absent from kwargs — no forced default injected" do
        interp, _ = make_interp
        interp.define_native("configure", kwarg_names: Set{"timeout"}) do |args, blk, ncc|
          Value.bool(ncc.kwargs.nil? || !ncc.kwargs.not_nil!.has_key?("timeout"))
        end
        interp.eval(%(configure())).as_bool.should be_true
      end

      it "a native function can self-serve a default for an omitted key, mruby-style" do
        interp, _ = make_interp
        interp.define_native("configure", kwarg_names: Set{"timeout"}) do |args, blk, ncc|
          timeout = ncc.kwargs.try(&.["timeout"]?) || Value.int(30_i64)
          timeout
        end
        interp.eval(%(configure())).as_int.should eq 30
        interp.eval(%(configure(timeout: 5))).as_int.should eq 5
      end

      it "positional args still bind normally alongside declared kwargs" do
        interp, _ = make_interp
        interp.define_native("greet", kwarg_names: Set{"loudly"}) do |args, blk, ncc|
          name = args.first.as_string
          loud = ncc.kwargs.try(&.["loudly"]?).try(&.as_bool) || false
          Value.string(loud ? name.upcase : name)
        end
        interp.eval(%(greet("bob", loudly: true))).as_string.should eq "BOB"
        interp.eval(%(greet("bob"))).as_string.should eq "bob"
      end
    end

    describe "a native `.new` (define_native_singleton_method) with declared kwarg_names" do
      it "accepts a declared keyword the same way an instance native method does" do
        interp, _ = make_interp
        cls = RubyClass.new("Config")
        new_sym = interp.symbols.intern("new").value
        cls.define_native_singleton_method(new_sym, RiskProfile.none, kwarg_names: Set{"retries"}) do |args, blk, ncc|
          retries = ncc.kwargs.try(&.["retries"]?) || Value.int(1_i64)
          obj = RubyObject.new(cls)
          obj.ivars[interp.symbols.intern("@retries").value] = retries
          Value.robject(obj)
        end
        retries_sym = interp.symbols.intern("retries").value
        cls.define_native_method(retries_sym, RiskProfile.none) do |args|
          args.first.as_robject.ivars[interp.symbols.intern("@retries").value]
        end
        interp.define_global_class(cls)
        interp.eval(%(Config.new(retries: 5).retries)).as_int.should eq 5
      end

      it "an undeclared keyword to a native .new still raises R012, not silently dropped" do
        interp, _ = make_interp
        cls = RubyClass.new("Config")
        new_sym = interp.symbols.intern("new").value
        cls.define_native_singleton_method(new_sym, RiskProfile.none, kwarg_names: Set{"retries"}) do |args, blk, ncc|
          Value.robject(RubyObject.new(cls))
        end
        interp.define_global_class(cls)
        error = expect_raises(RuntimeError) do
          interp.eval(%(Config.new(colour: "red")))
        end
        error.diagnostic.not_nil!.code.should eq("R012")
      end
    end

    # Found 2026-08-09 while diagnosing an unexpected failure: a
    # rejected kwarg-carrying native call left VM's @pending_kwargs
    # instance variable stale (only ever cleared AFTER dispatch_call
    # returns normally — a raise skips that reset entirely), and the
    # very next Op::Call executed anywhere — including
    # compile_rescue_clause_test's own compiled `is_a?` check, used to
    # match a raised exception against a `rescue ClassName => e`
    # clause's class list — inherited those stale kwargs. `is_a?`
    # declares no kwarg_names of its own, so the leaked keyword got
    # spuriously rejected with R012, masking the REAL exception
    # (RiskFlowPolicyError, ArgumentError, whatever actually raised)
    # entirely. Not specific to a native call being risk-flow-rejected
    # specifically — any raise mid-Op::Call while @pending_kwargs is
    # set reproduces this; risk-flow rejection is just the concrete
    # path these specs exercise. Fixed via VM#execute's Op::Call
    # handler wrapping dispatch_call in begin/ensure so
    # @pending_kwargs/@current_block/@current_block_locals reset
    # unconditionally, not just on the happy path.
    describe "a raise mid-call does not leak @pending_kwargs into a later, unrelated call" do
      it "a rejected kwarg-carrying call inside a TYPED rescue clause is still caught correctly, not masked by a spurious R012 from is_a?" do
        interp, _ = make_interp(risk_flow_policy: RiskFlowPolicy.reject_all)
        interp.define_native("tainted_value") do |args|
          Value.string("secret", RiskFlowLabel.of(ProvenanceKind::File, "secret", Sensitivity::High))
        end
        interp.define_native("risky_op", risk: RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error),
          kwarg_names: Set{"target"}) do |args, blk, ncc|
          Value.bool(true)
        end
        # Before the fix: this raised R012 ("unknown keyword: `target`",
        # method "is_a?") instead of being caught by the intended
        # RiskFlowPolicyError clause — the leaked kwargs poisoned the
        # rescue clause's own class-matching call.
        result = interp.eval(<<-RUBY)
          begin
            risky_op(target: tainted_value())
            :not_caught
          rescue RiskFlowPolicyError => e
            :caught
          end
          RUBY
        result.symbol?.should be_true
        result.as_sym.name.should eq "caught"
      end

      it "execution continues normally after the rescue — the leaked state doesn't poison anything further either" do
        interp, _ = make_interp(risk_flow_policy: RiskFlowPolicy.reject_all)
        interp.define_native("tainted_value") do |args|
          Value.string("secret", RiskFlowLabel.of(ProvenanceKind::File, "secret", Sensitivity::High))
        end
        interp.define_native("risky_op", risk: RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error),
          kwarg_names: Set{"target"}) do |args, blk, ncc|
          Value.bool(true)
        end
        # A plain, unrelated, kwarg-less call right after the rescue —
        # if @pending_kwargs (or @current_block) were still dirty,
        # this could misbehave in ways that have nothing to do with
        # risk flow at all.
        interp.eval(<<-RUBY).as_int.should eq 42
          begin
            risky_op(target: tainted_value())
          rescue RiskFlowPolicyError => e
          end
          40 + 2
          RUBY
      end

      it "a labeled value from a rejected kwarg call does not leak its label onto a later, unrelated call's risk evaluation" do
        # The risk-flow-specific angle: @pending_kwargs held a
        # Hash(String, Value) whose VALUE (not just its key) could in
        # principle carry a RiskFlowLabel. Confirms the leaked hash
        # (with its labeled value) never reaches ANY later dispatch —
        # not just that the key name stops causing R012, but that a
        # second risk-tagged call made right after is evaluated on ITS
        # OWN arguments only, with no spurious taint inherited from
        # the discarded call.
        interp, _ = make_interp(risk_flow_policy: RiskFlowPolicy.reject_all)
        interp.define_native("tainted_value") do |args|
          Value.string("secret", RiskFlowLabel.of(ProvenanceKind::File, "secret", Sensitivity::High))
        end
        interp.define_native("risky_op", risk: RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error),
          kwarg_names: Set{"target"}) do |args, blk, ncc|
          Value.bool(true)
        end
        # A SECOND risk-tagged native call, deliberately called with
        # NO kwargs and NO tainted argument at all — should proceed
        # cleanly. If the first call's leaked, labeled kwargs value
        # somehow fed into this one's risk evaluation, it would be
        # rejected too, even though nothing about THIS call is risky.
        interp.define_native("other_risky_op", risk: RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning)) do |args|
          Value.bool(true)
        end
        result = interp.eval(<<-RUBY)
          begin
            risky_op(target: tainted_value())
          rescue RiskFlowPolicyError => e
          end
          other_risky_op()
          RUBY
        result.as_bool.should be_true
      end
    end
  end
end
