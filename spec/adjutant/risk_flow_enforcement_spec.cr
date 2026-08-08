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
      RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::High, action),
    ])
  end

  # An interpreter with a native `delete_file(path)` tagged
  # RiskTag::DeletesFiles, whose return value is unlabeled (the risk
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
    interp.define_native("delete_file", risk: RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)) do |args|
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
        # rule table, regardless of what RiskTag the call carries.
        ef = TestEffectHandler.new
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::High, RiskFlowAction::Reject),
        ])
        interp = Interpreter.new(risk_flow_policy: policy, on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK, effect: ef)
        interp.define_native("delete_file", risk: RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)) do |args|
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
        match.rule.not_nil!.tag.should eq RiskTag::DeletesFiles
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
        req.risk.tags.should eq Set{RiskTag::DeletesFiles}
        req.risk.severity.should eq Severity::Error
      end

      it "does not call the callback when the sensitivity is None" do
        called = false
        callback = ->(req : RiskFlowDecisionRequest) {
          called = true
          RiskFlowDecision::Allow
        }
        policy = RiskFlowPolicy.new(risk_flow_rules: [
          RiskFlowRule.new(RiskTag::DeletesFiles, Sensitivity::High, RiskFlowAction::Ask),
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

    describe "RiskProfile.none (no tags)" do
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
  end
end
