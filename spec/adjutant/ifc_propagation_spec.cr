require "../spec_helper"

module Adjutant
  # Helper: an interpreter with flow tracking enabled and a native
  # function `tainted(origin)` that returns an Integer(1) labeled with a
  # single File tag at the given origin and Sensitivity::High — a
  # minimal stand-in for what a real native module (e.g. file IO) would
  # do once the sensitivity policy exists (see research/IFC_DESIGN.md).
  private def self.make_tainted_interp : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(effect: ef, flow_tracking: true)
    interp.define_native("tainted") do |args|
      origin = args.first.as_string
      Value.int(1_i64, SecurityLabel.of(ProvenanceKind::File, origin, Sensitivity::High))
    end
    interp.define_native("tainted_str") do |args|
      origin = args.first.as_string
      Value.string("x", SecurityLabel.of(ProvenanceKind::File, origin, Sensitivity::High))
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

      it "records a FlowEvent for Add" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd") + 1))
        events = interp.flow_log.events.select { |e| e.op == "Add" }
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

      it "records a FlowEvent for Eq" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd") == 1))
        interp.flow_log.events.map(&.op).should contain "Eq"
      end
    end

    describe "Op::Concat (string interpolation)" do
      it "joins labels across interpolated parts" do
        interp, _ = make_tainted_interp
        result = interp.eval(%q("value: #{tainted_str("/etc/passwd")}"))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a FlowEvent for Concat" do
        interp, _ = make_tainted_interp
        interp.eval(%q("value: #{tainted_str("/etc/passwd")}"))
        interp.flow_log.events.map(&.op).should contain "Concat"
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

      it "records a FlowEvent for MakeArray" do
        interp, _ = make_tainted_interp
        interp.eval(%([1, tainted("/etc/passwd"), 3]))
        interp.flow_log.events.map(&.op).should contain "MakeArray"
      end
    end

    describe "Op::MakeHash" do
      it "joins labels across keys and values onto the hash's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%({"k" => tainted("/etc/passwd")}))
        result.hash?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a FlowEvent for MakeHash" do
        interp, _ = make_tainted_interp
        interp.eval(%({"k" => tainted("/etc/passwd")}))
        interp.flow_log.events.map(&.op).should contain "MakeHash"
      end
    end

    describe "Op::MakeRange" do
      it "joins labels from start and end" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd")..5))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a FlowEvent for MakeRange" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd")..5))
        interp.flow_log.events.map(&.op).should contain "MakeRange"
      end
    end

    describe "flow_log disabled by default" do
      it "records nothing when flow_tracking is not enabled" do
        ef = TestEffectHandler.new
        interp = Interpreter.new(effect: ef)
        interp.define_native("tainted") do |args|
          Value.int(1_i64, SecurityLabel.of(ProvenanceKind::File, args.first.as_string, Sensitivity::High))
        end
        result = interp.eval(%(tainted("/etc/passwd") + 1))
        # Propagation itself is independent of flow_log — label still joins.
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
        interp.flow_log.events.should be_empty
      end
    end
  end
end
