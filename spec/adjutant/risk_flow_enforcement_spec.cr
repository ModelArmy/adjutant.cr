require "../spec_helper"

module Adjutant
  # These specs exercise the actual enforcement mechanism wired into
  # VM#call_native (check_risk_flow / raise_risk_flow_rejected) — the
  # live decision point, not just the RiskFlowPolicy lookup logic
  # already covered in risk_flow_policy_spec.cr.

  # A policy with one risk_flow_rule mapping DeletesFiles x High to
  # the given action. No sensitivity_patterns needed — tainted_path
  # (below) bakes in Sensitivity::High directly, the way a real
  # native module would after calling interp.risk_flow_policy
  # .sensitivity_for(...) itself once, rather than the VM re-deriving
  # sensitivity from a pattern at check time (it doesn't — sensitivity
  # lives on the ProvenanceTag already, set when the tag was created).
  private def self.enforcement_policy_for(action : RiskFlowAction) : RiskFlowPolicy
    RiskFlowPolicy.new(risk_flow_rules: [
      RiskFlowRule.new(Effect::DeletesFiles, Sensitivity::High, action),
    ])
  end

  # An interpreter with a native `delete_file(path)` tagged
  # Effect::DeletesFiles, whose return value is unlabeled (the risk
  # comes from the tainted *argument*, matching how a real File
  # module would label the path it was given, not what it returns).
  private def self.make_enforcement_interp(
    risk_flow_policy : RiskFlowPolicy,
    on_risk_flow_decision : RiskFlowDecisionRequest -> RiskFlowDecision = TEST_UNEXPECTED_ASK_CALLBACK,
  ) : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(
      risk_flow_policy: risk_flow_policy,
      on_risk_flow_decision: on_risk_flow_decision,
      effect: ef,
    )
    interp.define_native("delete_file", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)) do |args|
      Value.bool(true)
    end
    # Sensitivity is baked in at tag-creation time (High), the way a
    # real File module would after consulting policy itself — see
    # research/IFC_DESIGN.md's ScriptModule labeling convention.
    interp.define_native("tainted_path") do |args|
      Value.string(args.first.as_string, RiskFlowLabel.of(ProvenanceKind::File, args.first.as_string, Sensitivity::High))
    end
    {interp, ef}
  end

  describe "risk flow enforcement (piece 4)" do
    describe "no taint, no check" do
      it "a risky call with plain unlabeled arguments proceeds under reject_all" do
        interp, _ = make_enforcement_interp(RiskFlowPolicy.reject_all)
        result = interp.eval(%(delete_file("/tmp/scratch")))
        result.as_bool.should be_true
      end

      it "a risky call with an untainted-sensitivity (None) argument proceeds" do
        # A label with Sensitivity::None (e.g. a public/non-sensitive
        # source) never reaches the Reject rule below — action_for's
        # None short-circuit means the check never even consults the
        # rule table, regardless of what Effect the call carries.
        ef = TestEffectHandler.new
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(Effect::DeletesFiles, Sensitivity::High, RiskFlowAction::Reject),
        ])
        interp = Interpreter.new(risk_flow_policy: policy, on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK, effect: ef)
        interp.define_native("delete_file", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)) do |args|
          Value.bool(true)
        end
        interp.define_native("public_path") do |args|
          Value.string(args.first.as_string, RiskFlowLabel.of(ProvenanceKind::File, args.first.as_string, Sensitivity::None))
        end
        result = interp.eval(%(delete_file(public_path("/tmp/scratch"))))
        result.as_bool.should be_true
      end
    end

    describe "RiskFlowAction::Reject" do
      it "raises when a tainted argument matches a Reject rule" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(%(delete_file(tainted_path("/etc/passwd"))))
        end
        # An F code, not an R: nothing is broken. The policy declined a
        # call it was configured to decline, and the reader may well be
        # whoever wrote the policy rather than whoever wrote the script.
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
        diag.data["call"].should eq("delete_file")
      end

      it "raises when a tainted argument matches a Reject rule, reached via super" do
        # define_native registers onto Object's own native_methods
        # table, so a plain script class inherits delete_file/
        # tainted_path from its default Object superclass — a script
        # method overriding delete_file and calling `super(path)`
        # dispatches through VM#dispatch_super's native-method branch
        # (Op::Super), NOT the ordinary Op::Call path every other
        # test in this file exercises. Passes because dispatch_super
        # routes through the exact same call_native — and therefore
        # the exact same check_risk_flow — every other native call
        # already goes through; nothing dispatch_super-specific was
        # needed. Proven here rather than only reasoned about.
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            class Wrapper
              def delete_file(path)
                super(path)
              end
            end
            Wrapper.new.delete_file(tainted_path("/etc/passwd"))
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
      end

      it "the raised error is a script-visible RiskFlowRejectedError" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue e
            e
          end
        RUBY
        result.robject?.should be_true
        result.as_robject.rclass.name.should eq "RiskFlowRejectedError"
      end

      it "is catchable via the RiskFlowPolicyError superclass" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue RiskFlowPolicyError => e
            :caught
          end
        RUBY
        result.symbol?.should be_true
        result.as_sym.name.should eq "caught"
      end

      it "is catchable via a bare rescue (RiskFlowRejectedError is a StandardError descendant)" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue e
            :caught
          end
        RUBY
        result.symbol?.should be_true
        result.as_sym.name.should eq "caught"
      end

      it "the call's side effect does not happen when rejected" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          deleted = false
          begin
            delete_file(tainted_path("/etc/passwd"))
            deleted = true
          rescue e
            nil
          end
          deleted
        RUBY
        result.as_bool.should be_false
      end

      it "e.message describes the rejected call" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue e
            e.message
          end
        RUBY
        result.as_string.should contain("delete_file")
      end
    end

    describe "RiskFlowAction::Ask" do
      it "calls on_risk_flow_decision and proceeds when it returns Allow" do
        called_with = nil.as(RiskFlowDecisionRequest?)
        callback = ->(req : RiskFlowDecisionRequest) {
          called_with = req
          RiskFlowDecision::Allow
        }
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Ask), callback)
        result = interp.eval(%(delete_file(tainted_path("/etc/passwd"))))
        result.as_bool.should be_true
        called_with.should_not be_nil
      end

      it "raises when on_risk_flow_decision returns Reject" do
        callback = ->(req : RiskFlowDecisionRequest) { RiskFlowDecision::Reject }
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Ask), callback)
        expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(%(delete_file(tainted_path("/etc/passwd"))))
        end
      end

      it "the decision request carries the call name" do
        called_with = nil.as(RiskFlowDecisionRequest?)
        callback = ->(req : RiskFlowDecisionRequest) {
          called_with = req
          RiskFlowDecision::Allow
        }
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Ask), callback)
        interp.eval(%(delete_file(tainted_path("/etc/passwd"))))
        called_with.not_nil!.call_name.should eq "delete_file"
      end

      it "the decision request carries the matched rule and tag" do
        called_with = nil.as(RiskFlowDecisionRequest?)
        callback = ->(req : RiskFlowDecisionRequest) {
          called_with = req
          RiskFlowDecision::Allow
        }
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Ask), callback)
        interp.eval(%(delete_file(tainted_path("/etc/passwd"))))
        req = called_with.not_nil!
        req.matches.size.should eq 1
        match = req.matches.first
        match.action.should eq RiskFlowAction::Ask
        match.rule.not_nil!.tag.should eq Effect::DeletesFiles
        match.tag.origin.should eq "/etc/passwd"
        match.tag.kind.should eq ProvenanceKind::File
      end

      it "the decision request carries the call's RiskProfile" do
        called_with = nil.as(RiskFlowDecisionRequest?)
        callback = ->(req : RiskFlowDecisionRequest) {
          called_with = req
          RiskFlowDecision::Allow
        }
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Ask), callback)
        interp.eval(%(delete_file(tainted_path("/etc/passwd"))))
        req = called_with.not_nil!
        req.risk.effects.should eq Set{Effect::DeletesFiles}
        req.risk.severity.should eq Severity::Error
      end

      it "does not call the callback when the sensitivity is None" do
        called = false
        callback = ->(req : RiskFlowDecisionRequest) {
          called = true
          RiskFlowDecision::Allow
        }
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(Effect::DeletesFiles, Sensitivity::High, RiskFlowAction::Ask),
        ])
        interp, _ = make_enforcement_interp(policy, callback)
        interp.eval(%(delete_file("/tmp/scratch")))
        called.should be_false
      end
    end

    describe "RiskFlowPolicy.reject_all" do
      it "rejects a tainted call with no risk_flow_rules configured" do
        interp, _ = make_enforcement_interp(RiskFlowPolicy.reject_all)
        expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(%(delete_file(tainted_path("/etc/passwd"))))
        end
      end
    end

    describe "RiskProfile.none (no effects)" do
      it "never triggers a risk flow check regardless of policy" do
        ef = TestEffectHandler.new
        interp = Interpreter.new(
          risk_flow_policy: RiskFlowPolicy.reject_all,
          on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
          effect: ef,
        )
        interp.define_native("harmless") do |args|
          Value.int(1_i64, RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High))
        end
        result = interp.eval(%(harmless() + 1))
        result.as_int.should eq 2_i64
      end
    end

    # A rejected risk-flow call is a real, script-catchable error
    # (RiskFlowRejectedError < RiskFlowPolicyError < StandardError —
    # see the single-clause coverage above). Multiple rescue clauses
    # landed this session (see SCOPE.md), so this is the actual
    # runtime interaction, not just the static walker's view of it:
    # does a multi-clause rescue correctly single out a policy
    # rejection from other error types, in real class-filter order?
    describe "multiple rescue clauses catching a rejected risk flow call" do
      it "a later, more specific clause catches the rejection when an " \
         "earlier clause's class doesn't match" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue TypeError => e
            "wrong branch"
          rescue RiskFlowPolicyError => e
            "caught: " + e.message
          end
        RUBY
        result.as_string.should contain("delete_file")
        result.as_string.should start_with("caught: ")
      end

      it "an earlier, broader clause intercepts the rejection before a later, " \
         "more specific one gets a chance — real Ruby order-not-specificity, " \
         "worth knowing as a script-authoring pitfall for this error family " \
         "specifically" do
        # Same "first match wins, never most-specific" semantics
        # confirmed for ordinary classes in begin_rescue_ensure/vm_spec.cr
        # ("picks first-listed on order, not most-specific"), but here
        # with StandardError positioned first, ahead of the narrower
        # RiskFlowPolicyError a script author might expect to run
        # instead. Worth its own test: this is exactly the shape a
        # generated script could get wrong if it lists a catch-all
        # rescue before a specific policy-rejection handler.
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue StandardError => e
            "generic"
          rescue RiskFlowPolicyError => e
            "specific"
          end
        RUBY
        result.as_string.should eq "generic"
      end

      it "rescue RiskFlowPolicyError, TypeError catches the rejection via the " \
         "multiple-classes-on-one-clause form" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue RiskFlowPolicyError, TypeError => e
            "caught"
          end
        RUBY
        result.as_string.should eq "caught"
      end

      it "falls through every mismatched clause and still re-raises the " \
         "rejection uncaught when nothing matches" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        # A reraise past a mismatched clause loses the original
        # Diagnostic by design (Op::Reraise's RuntimeError.new(message,
        # frame, error_value:) sets @diagnostic = nil — see vm.cr; the
        # diagnostic is a report about a fresh VM-classified failure,
        # and this is the script's own error re-propagating, not a
        # new one). So this checks the message, same as every other
        # uncaught-mismatch test in this file, rather than .diagnostic.
        expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            begin
              delete_file(tainted_path("/etc/passwd"))
            rescue TypeError => e
              "wrong"
            rescue ArgumentError => e
              "also wrong"
            end
          RUBY
        end
      end

      it "the call's side effect still does not happen, now behind two " \
         "mismatched clauses before the one that matches" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          deleted = false
          begin
            delete_file(tainted_path("/etc/passwd"))
            deleted = true
          rescue TypeError => e
            nil
          rescue ArgumentError => e
            nil
          rescue RiskFlowPolicyError => e
            nil
          end
          deleted
        RUBY
        result.as_bool.should be_false
      end
    end

    # `else` runs bytecode through the exact same VM#call_native path
    # as anywhere else in a script — enforcement needed no changes for
    # it. These confirm that directly, plus the one genuinely
    # else-specific interaction: a rejection raised INSIDE else must
    # NOT be caught by that same begin's own rescue clauses (see
    # begin_rescue_ensure/vm_spec.cr's equivalent coverage for a plain
    # `raise`; this is the same rule, exercised through real risk-flow
    # rejection instead).
    describe "a rejected risk flow call inside an else clause" do
      it "a tainted call inside else is rejected the same as anywhere else" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            begin
              1 + 1
            rescue e
              "rescued"
            else
              delete_file(tainted_path("/etc/passwd"))
            end
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
      end

      it "is NOT caught by that same begin's own rescue clause" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            begin
              1 + 1
            rescue RiskFlowPolicyError => e
              "should not catch this"
            else
              delete_file(tainted_path("/etc/passwd"))
            end
          RUBY
        end
      end

      it "IS catchable by an outer begin's rescue, since it's an ordinary " \
         "propagating error by the time it's past this begin's else" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          begin
            begin
              1 + 1
            rescue e
              "inner rescued"
            else
              delete_file(tainted_path("/etc/passwd"))
            end
          rescue RiskFlowPolicyError => e
            "outer caught"
          end
        RUBY
        result.as_string.should eq "outer caught"
      end

      it "a tainted call in the body being rejected means else never runs " \
         "at all — the call's own side effect proves it" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          else_ran = false
          begin
            delete_file(tainted_path("/etc/passwd"))
          rescue RiskFlowPolicyError => e
            "rejected in body"
          else
            else_ran = true
          end
          else_ran
        RUBY
        result.as_bool.should be_false
      end
    end

    # Op::SetAttr (2026-08-08) reaching a NATIVE setter — currently
    # dormant in practice (no `native_methods` entry ending in `=` is
    # registered anywhere in this codebase today, confirmed by grep),
    # but the path is real: `VM#call_method` (what `Op::SetAttr` uses
    # to dispatch a setter call) reuses the exact same `dispatch_call`
    # -> `call_native` -> `check_risk_flow` chain every other native
    # call goes through — see `Interpreter#define_native`'s own
    # comment (it always registers onto `Object`'s native_methods
    # table, found via `RubyClass#find_native_method`'s ordinary
    # ancestor walk, so ANY receiver class picks it up, exactly like
    # a real inherited method would). This describe block proves that
    # reused path actually enforces correctly starting from
    # `Op::SetAttr` specifically, not just from an ordinary `Op::Call`
    # — nothing had exercised it from this direction before.
    describe "Op::SetAttr reaching a native setter (dormant today, real path)" do
      it "raises when a tainted value assigned via recv.attr = value matches a Reject rule" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        interp.define_native("value=", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)) do |args|
          Value.bool(true)
        end
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            class Box
            end
            Box.new.value = tainted_path("/etc/passwd")
            RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
        # "Box#value=", not bare "value=" — dispatch_call's own
        # existing naming convention for a receiver-based instance
        # method call ("#{cls.name}##{name}", matching Ruby's own
        # Box#value= convention), same as any other native call
        # through a receiver; nothing Op::SetAttr-specific about it.
        diag.data["call"].should eq("Box#value=")
      end

      it "the call's side effect does not happen when rejected, same as any other native call" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        effect_ran = false
        interp.define_native("value=", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)) do |args|
          effect_ran = true
          Value.bool(true)
        end
        interp.eval(<<-RUBY)
          class Box
          end
          begin
            Box.new.value = tainted_path("/etc/passwd")
          rescue RiskFlowPolicyError => e
          end
          RUBY
        effect_ran.should be_false
      end

      it "an untainted value assigned via recv.attr = value proceeds normally" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        interp.define_native("value=", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)) do |args|
          Value.bool(true)
        end
        result = interp.eval(<<-RUBY)
          class Box
          end
          Box.new.value = "clean"
          RUBY
        result.as_string.should eq "clean"
      end
    end

    # Native kwarg support (2026-08-09): a labeled value passed as a
    # KEYWORD argument to a risk-tagged native call must be enforced
    # exactly like a positional one — see VM#check_risk_flow's own
    # comment for why this wasn't previously reachable at all (native
    # calls unconditionally rejected any kwargs before this session).
    describe "a tainted value reaching a risk-tagged native call via a keyword argument" do
      it "raises when a tainted kwarg value matches a Reject rule" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        interp.define_native("delete_at", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error),
          kwarg_names: Set{"path"}) do |args, blk, ncc|
          Value.bool(true)
        end
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(%(delete_at(path: tainted_path("/etc/passwd"))))
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
        diag.data["call"].should eq("delete_at")
      end

      it "the call's side effect does not happen when the kwarg value is rejected" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        effect_ran = false
        interp.define_native("delete_at", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error),
          kwarg_names: Set{"path"}) do |args, blk, ncc|
          effect_ran = true
          Value.bool(true)
        end
        interp.eval(<<-RUBY)
          begin
            delete_at(path: tainted_path("/etc/passwd"))
          rescue RiskFlowPolicyError => e
          end
          RUBY
        effect_ran.should be_false
      end

      it "an untainted kwarg value proceeds normally" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        interp.define_native("delete_at", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error),
          kwarg_names: Set{"path"}) do |args, blk, ncc|
          Value.bool(true)
        end
        result = interp.eval(%(delete_at(path: "/tmp/scratch")))
        result.as_bool.should be_true
      end

      it "a tainted POSITIONAL argument alongside an untainted kwarg is still enforced (kwargs don't crowd out args)" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        interp.define_native("delete_with_mode", risk: RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error),
          kwarg_names: Set{"mode"}) do |args, blk, ncc|
          Value.bool(true)
        end
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(%(delete_with_mode(tainted_path("/etc/passwd"), mode: "force")))
        end
        error.diagnostic.not_nil!.code.should eq("F001")
      end
    end

    describe "a native call with kwarg_names declared" do
      it "an unknown keyword name still raises R012, same as any other native call" do
        interp, _ = make_enforcement_interp(RiskFlowPolicy.reject_all)
        interp.define_native("configure", kwarg_names: Set{"timeout"}) do |args, blk, ncc|
          Value.bool(true)
        end
        error = expect_raises(RuntimeError) do
          interp.eval(%(configure(retries: 3)))
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("R012")
        diag.data["name"].should eq("retries")
      end

      it "a declared keyword name is accessible via NativeCallContext#kwargs" do
        interp, _ = make_enforcement_interp(RiskFlowPolicy.reject_all)
        seen = nil
        interp.define_native("configure", kwarg_names: Set{"timeout"}) do |args, blk, ncc|
          seen = ncc.kwargs.try(&.["timeout"]?).try(&.as_int)
          Value.nil_value
        end
        interp.eval(%(configure(timeout: 30)))
        seen.should eq(30)
      end
    end

    describe "include (a tainted value reached through an included module's method)" do
      # `find_method`/`find_native_method` being module-aware handles
      # RESOLUTION — this confirms the separate, actually-important
      # question: does the DYNAMIC blocking layer still fire when the
      # native call in question is reached via a mixed-in method, not
      # written directly on the class? It should, automatically —
      # `dispatch_call`'s native-call branch routes through the exact
      # same `call_native`/`check_risk_flow` regardless of which
      # RubyClass (self, an ancestor, or an included module) the
      # resolved method actually came from — proven here rather than
      # only reasoned about, same standard the earlier `super`-reached
      # case (above) was held to.
      it "raises when a tainted argument matches a Reject rule, reached through an included module's method" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            module Deleter
              def remove(path)
                delete_file(path)
              end
            end
            class Wrapper
              include Deleter
            end
            Wrapper.new.remove(tainted_path("/etc/passwd"))
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
        diag.data["call"].should eq("delete_file")
      end

      it "raises when the tainted value reaches the native call via BOTH include and super together" do
        # Wrapper's own `delete_file` override calls super — dispatch
        # goes: Wrapper#delete_file (script) -> super -> Deleter's
        # own included copy of the ORIGINAL delete_file is not in
        # play here (nothing shadows it) -> the real native
        # delete_file on Object. Confirms the combination doesn't
        # open a gap either half's own test didn't already cover
        # alone.
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            module Noop
            end
            class Wrapper
              include Noop
              def delete_file(path)
                super(path)
              end
            end
            Wrapper.new.delete_file(tainted_path("/etc/passwd"))
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
      end

      it "an UNTAINTED value reaching the same native call through an included module does NOT raise" do
        # Negative case — confirms the include path doesn't
        # over-trigger enforcement for ordinary, non-risky-content
        # calls, not just that it correctly blocks risky ones.
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        interp.eval(<<-RUBY)
          module Deleter
            def remove(path)
              delete_file(path)
            end
          end
          class Wrapper
            include Deleter
          end
          Wrapper.new.remove("/tmp/plain_ordinary_path")
        RUBY
      end
    end

    describe "extend (a tainted value reached through an extended module's method, as a CLASS method)" do
      # Same question as include's own describe block above, on the
      # singleton side: does the dynamic blocking layer still fire
      # when the native call is reached via a class method mixed in
      # by `extend`, not written directly on the class? Same
      # reasoning applies — `dispatch_call`'s native-call branch
      # doesn't care which RubyClass (self, an ancestor, or an
      # extended module) the resolved method actually came from,
      # proven here rather than only reasoned about.
      it "raises when a tainted argument matches a Reject rule, reached through an extended module's method called as a class method" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            module Deleter
              def remove(path)
                delete_file(path)
              end
            end
            class Wrapper
              extend Deleter
            end
            Wrapper.remove(tainted_path("/etc/passwd"))
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
        diag.data["call"].should eq("delete_file")
      end

      it "raises when the tainted value reaches the native call via BOTH extend and singleton super together" do
        # Wrapper's own class-method delete_file override calls
        # super — dispatch goes: Wrapper.delete_file (script,
        # singleton) -> super -> Base's own class method (script,
        # singleton), found via singleton_ancestors past the extended
        # Noop module (which has no matching method) -> Base's own
        # class method makes an ORDINARY (non-super) bare call to the
        # native delete_file, reached via self_rclass.rclass's own
        # chain the normal way. Deliberately NOT routing delete_file
        # itself through super — real Ruby's singleton super never
        # reaches Object's ORDINARY (non-singleton) native instance
        # methods at all, so that shape isn't a valid reproduction;
        # this still exercises the extend+super COMBINATION, just
        # with the actual risky call one level further in.
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            module Noop
            end
            class Base
              def self.risky_op(path)
                delete_file(path)
              end
            end
            class Wrapper < Base
              extend Noop
              def self.risky_op(path)
                super(path)
              end
            end
            Wrapper.risky_op(tainted_path("/etc/passwd"))
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
      end

      it "an UNTAINTED value reaching the same native call through an extended module does NOT raise" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        interp.eval(<<-RUBY)
          module Deleter
            def remove(path)
              delete_file(path)
            end
          end
          class Wrapper
            extend Deleter
          end
          Wrapper.remove("/tmp/plain_ordinary_path")
        RUBY
      end
    end

    # End-to-end: a value that picked up its taint via Regexp/MatchData
    # (risk_flow_propagation_spec.cr's own concern — does the LABEL
    # survive the trip) reaching a risky call and actually getting
    # rejected (this file's own concern — does the enforcement
    # DECISION fire). Neither spec alone proves the two compose
    # correctly; this does, without re-testing either layer's own
    # logic in isolation. Added 2026-08-14 after the Regexp IFC audit,
    # per the same "propagation coverage and enforcement coverage are
    # two different questions" reasoning that motivated NOT folding
    # this into risk_flow_propagation_spec.cr itself.
    describe "a value extracted via Regexp/MatchData reaching a risky call" do
      it "a MatchData capture group extracted from a tainted subject is rejected" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            path = tainted_path("/etc/passwd")
            md = /etc\\/(\\w+)/.match(path)
            delete_file(md[1])
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("F001")
        diag.data["call"].should eq("delete_file")
      end

      it "a String#gsub result built from a tainted receiver is rejected" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        error = expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
            path = tainted_path("/etc/passwd")
            cleaned = path.gsub(/^\\//, "")
            delete_file(cleaned)
          RUBY
        end
        error.diagnostic.not_nil!.code.should eq("F001")
      end

      it "a MatchData capture group extracted from an UNTAINTED subject does NOT raise" do
        interp, _ = make_enforcement_interp(enforcement_policy_for(RiskFlowAction::Reject))
        result = interp.eval(<<-RUBY)
          md = /etc\\/(\\w+)/.match("/etc/plain_ordinary_path")
          delete_file(md[1])
        RUBY
        result.as_bool.should be_true
      end
    end
  end
end
