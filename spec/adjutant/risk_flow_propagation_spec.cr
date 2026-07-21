require "../spec_helper"

module Adjutant
  # Helper: an interpreter with flow tracking enabled and a native
  # function `tainted(origin)` that returns an Integer(1) labeled with a
  # single File tag at the given origin and Sensitivity::High — a
  # minimal stand-in for what a real native module (e.g. file IO) would
  # do once the sensitivity policy exists (see research/IFC_DESIGN.md).
  private def self.make_tainted_interp : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(
      risk_flow_policy: RiskFlowPolicy.reject_all,
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      effect: ef,
      risk_flow_tracking: true,
    )
    interp.define_native("tainted") do |args|
      origin = args.first.as_string
      Value.int(1_i64, RiskFlowLabel.of(ProvenanceKind::File, origin, Sensitivity::High))
    end
    interp.define_native("tainted_str") do |args|
      origin = args.first.as_string
      Value.string("x", RiskFlowLabel.of(ProvenanceKind::File, origin, Sensitivity::High))
    end
    {interp, ef}
  end

  describe "IFC label propagation through VM dispatch (Stage 3)" do
    describe "arithmetic (exec_binary)" do
      it "joins labels across Add" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") + 1))
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/passwd"
      end

      it "an unlabeled result stays unlabeled" do
        interp, _ = make_tainted_interp
        interp.eval("1 + 1").label.should be_nil
      end

      it "joins labels from both operands when both are tainted" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") + tainted("/etc/shadow")))
        label = result.label.not_nil!
        label.tags.size.should eq 2
      end

      it "records a RiskFlowEvent for Add" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd") + 1))
        events = interp.risk_flow_log.events.select { |e| e.op == "Add" }
        events.size.should eq 1
        events.first.result.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "joins across comparison ops" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") < 5))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    describe "Op::Eq" do
      it "joins labels across equality comparison" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") == 1))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for Eq" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd") == 1))
        interp.risk_flow_log.events.map(&.op).should contain "Eq"
      end
    end

    describe "Op::Concat (string interpolation)" do
      it "joins labels across interpolated parts" do
        interp, _ = make_tainted_interp
        result = interp.eval(%q("value: #{tainted_str("/etc/passwd")}"))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for Concat" do
        interp, _ = make_tainted_interp
        interp.eval(%q("value: #{tainted_str("/etc/passwd")}"))
        interp.risk_flow_log.events.map(&.op).should contain "Concat"
      end
    end

    describe "Op::MakeArray" do
      it "joins labels across array elements onto the array's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%([1, tainted("/etc/passwd"), 3]))
        result.array?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "an array of unlabeled elements stays unlabeled" do
        interp, _ = make_tainted_interp
        interp.eval("[1, 2, 3]").label.should be_nil
      end

      it "records a RiskFlowEvent for MakeArray" do
        interp, _ = make_tainted_interp
        interp.eval(%([1, tainted("/etc/passwd"), 3]))
        interp.risk_flow_log.events.map(&.op).should contain "MakeArray"
      end
    end

    describe "Op::MakeHash" do
      it "joins labels across keys and values onto the hash's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%({"k" => tainted("/etc/passwd")}))
        result.hash?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for MakeHash" do
        interp, _ = make_tainted_interp
        interp.eval(%({"k" => tainted("/etc/passwd")}))
        interp.risk_flow_log.events.map(&.op).should contain "MakeHash"
      end
    end

    describe "Op::MakeRange" do
      it "joins labels from start and end" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd")..5))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for MakeRange" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd")..5))
        interp.risk_flow_log.events.map(&.op).should contain "MakeRange"
      end
    end

    describe "Op::SetIndex (container accumulation, Stage 4)" do
      it "accumulates a tainted element's label onto the array's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
          arr
        RUBY
        result.array?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "the accumulated label is visible via a later GetLocal read of the same array" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
          post_target = arr
          post_target
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "does not taint the array when the assigned value is unlabeled" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = 99
          arr
        RUBY
        result.label.should be_nil
      end

      it "accumulates onto a Hash's own label the same way" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1}
          h["a"] = tainted("/etc/passwd")
          h
        RUBY
        result.hash?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for SetIndex" do
        interp, _ = make_tainted_interp
        interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
        RUBY
        events = interp.risk_flow_log.events.select { |e| e.op == "SetIndex" }
        events.size.should eq 1
        events.first.result.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "labels accumulate monotonically — overwriting the tainted slot does not clear the array's label" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
          arr[0] = "clean"
          arr
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    describe "Op::Shl (<<, container accumulation)" do
      it "accumulates a pushed tainted value's label onto the array" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = []
          arr << tainted("/etc/passwd")
          arr
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "chained << calls all accumulate" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = []
          arr << 1 << tainted("/etc/passwd") << 3
          arr
        RUBY
        result.array?.should be_true
        result.as_array.size.should eq 3
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    describe "risk_flow_log disabled by default" do
      it "records nothing when flow_tracking is not enabled" do
        ef = TestEffectHandler.new
        interp = Interpreter.new(
          risk_flow_policy: RiskFlowPolicy.reject_all,
          on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
          effect: ef,
        )
        interp.define_native("tainted") do |args|
          Value.int(1_i64, RiskFlowLabel.of(ProvenanceKind::File, args.first.as_string, Sensitivity::High))
        end
        result = interp.eval(%(tainted("/etc/passwd") + 1))
        # Propagation itself is independent of risk_flow_log — label still joins.
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
        interp.risk_flow_log.events.should be_empty
      end
    end

    # Closes the "verify IFC label propagation through lambdas" Must
    # Fix item (SCOPE.md) — the dynamic-label counterpart to the
    # 2026-07-20 VALUE-level closure-capture fix (#17,
    # research/IFC_DESIGN.md's "VM propagation" section). That fix
    # made a lambda's closure resolve to the right VALUE regardless of
    # which frame calls it; these specs confirm a LABELED value
    # specifically still carries its label correctly through the same
    # paths — capture into a closure (GetOuter/SetOuter, "free
    # propagation" per the design doc, since Value is a struct copied
    # whole) and a lambda body's own result flowing back out through
    # `.call` (VM#invoke_proc, unrelated to exec_binary's join logic
    # tested elsewhere in this file — a lambda's return value is
    # whatever its body's last expression evaluates to, propagated by
    # the ordinary rules already covered above, not a special path of
    # its own).
    describe "lambdas and Proc#call" do
      it "a label survives capture into a lambda's closure and a same-frame .call" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          secret = tainted("/etc/passwd")
          wrap = ->() { secret }
          wrap.call
        RUBY
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/passwd"
      end

      it "a label survives a lambda returned out of its defining frame and .call'd from elsewhere" do
        # Same shape as proc_spec.cr's "closes over its defining
        # frame's local..." regression (the VALUE-level version of
        # this exact test) — a lambda captures a labeled local, is
        # returned out of the function that defined it, and is called
        # later from a completely different frame (top level).
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def make_wrapper
            secret = tainted("/etc/passwd")
            ->() { secret }
          end

          wrap = make_wrapper
          wrap.call
        RUBY
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/passwd"
      end

      it "a label on a lambda's own computed result survives .call's return, not just a bare captured value" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          add_taint = ->() { tainted("/etc/shadow") + 1 }
          add_taint.call
        RUBY
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/shadow"
      end

      it "a labeled value captured by a lambda still joins correctly with another tainted value inside the lambda body" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def make_combiner
            a = tainted("/etc/passwd")
            ->() { a + tainted("/etc/shadow") }
          end
          make_combiner.call
        RUBY
        label = result.label.not_nil!
        label.tags.size.should eq 2
      end

      it "an unlabeled value captured by a lambda stays unlabeled through .call" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def make_wrapper
            plain = 42
            ->() { plain }
          end
          make_wrapper.call
        RUBY
        result.label.should be_nil
      end
    end
  end
end
