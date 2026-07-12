require "../spec_helper"

module Adjutant
  describe RiskFlowEvent do
    it "round-trips through JSON" do
      original = RiskFlowEvent.new(
        op: "Add",
        inputs: [RiskFlowLabel.of(ProvenanceKind::File, "/etc/hosts"), nil],
        result: RiskFlowLabel.of(ProvenanceKind::File, "/etc/hosts"),
        line: 12
      )
      parsed = RiskFlowEvent.from_json(original.to_json)
      parsed.op.should eq "Add"
      parsed.inputs.size.should eq 2
      parsed.inputs[0].should eq original.inputs[0]
      parsed.inputs[1].should be_nil
      parsed.result.should eq original.result
      parsed.line.should eq 12
    end
  end

  describe RiskFlowLog do
    it "is disabled by default" do
      RiskFlowLog.new.enabled?.should be_false
    end

    it "does not record events when disabled" do
      log = RiskFlowLog.new(enabled: false)
      log.record("Add", [nil, nil] of RiskFlowLabel?, nil, 1)
      log.events.should be_empty
    end

    it "records events when enabled" do
      log = RiskFlowLog.new(enabled: true)
      log.record("Add", [nil, nil] of RiskFlowLabel?, nil, 1)
      log.events.size.should eq 1
      log.events.first.op.should eq "Add"
    end

    it "accumulates multiple events in order" do
      log = RiskFlowLog.new(enabled: true)
      log.record("Add", [nil, nil] of RiskFlowLabel?, nil, 1)
      log.record("Concat", [nil, nil] of RiskFlowLabel?, nil, 2)
      log.events.map(&.op).should eq ["Add", "Concat"]
    end

    it "clear empties recorded events" do
      log = RiskFlowLog.new(enabled: true)
      log.record("Add", [nil, nil] of RiskFlowLabel?, nil, 1)
      log.clear
      log.events.should be_empty
    end

    describe "JSON round-trip" do
      it "round-trips an empty log" do
        original = RiskFlowLog.new(enabled: true)
        parsed = RiskFlowLog.from_json(original.to_json)
        parsed.enabled?.should be_true
        parsed.events.should be_empty
      end

      it "round-trips a log with events, preserving labels" do
        original = RiskFlowLog.new(enabled: true)
        original.record(
          "SetIndex",
          [RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)] of RiskFlowLabel?,
          RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High),
          42
        )
        parsed = RiskFlowLog.from_json(original.to_json)
        parsed.events.size.should eq 1
        event = parsed.events.first
        event.op.should eq "SetIndex"
        event.line.should eq 42
        event.result.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end
  end
end
