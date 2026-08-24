require "../../spec_helper"

module Adjutant
  # Same pattern `risk_flow_propagation_spec.cr` (core Adjutant)
  # already establishes for the VM's own operators, applied to
  # Legate's value types and Stream. Verifies that a tainted input
  # Value's label actually SURVIVES construction/transformation,
  # not just that the resulting DATA is computed correctly — a
  # genuinely separate axis from `value_types_spec.cr`/`stream_spec.cr`,
  # kept in its own file for the same reason core Adjutant keeps its
  # own `risk_flow_*_spec.cr` suite separate from ordinary behavioral
  # specs (`spec/adjutant/builtins/*`).
  #
  # `tainted`/`tainted_str` mirror the core spec's own minimal
  # stand-in for "what a real native module would do once sensitivity
  # policy exists" (see that file's own comment, and
  # `research/IFC_DESIGN.md`) — a single File-provenance, High-
  # sensitivity label, exactly the shape a real Legate verb reading a
  # sensitive file will eventually produce.
  private def self.make_legate_ifc_interp : Interpreter
    interp, _ = make_interp
    interp.define_native("tainted_str") do |args|
      origin = args.first.as_string
      Value.string("x", RiskFlowLabel.of(ProvenanceKind::File, origin, Sensitivity::High))
    end
    interp
  end

  # Stat/Entry/Match/Response/Exit are broker-manufactured only (no
  # script-visible constructor — see each file's own comment), so
  # their propagation is tested by calling `.build` directly from
  # Crystal with a real `RiskFlowLabel`, via the same kind of
  # throwaway native-trigger pattern `value_types_spec.cr` already
  # established, rather than through `eval`.
  private def self.interp_with_labeled_value_triggers : Interpreter
    interp, _ = make_interp
    interp.modules.register("test/legate_ifc_triggers") do |i|
      legate = i.get_global("Legate").as_rclass
      label = RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)

      i.define_native("labeled_stat") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Stat").value].as_rclass
        time_cls = i.get_global("Time").as_rclass
        now = Value.robject(TimeObject.new(time_cls, ::Time.local))
        Legate::Stat.build(i, cls, :file, 1024_i64, now, 0o644, label)
      end

      i.define_native("labeled_entry") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Entry").value].as_rclass
        path_cls = legate.constants[i.symbols.intern("Path").value].as_rclass
        path = Legate::Path.from_string(i, path_cls, "logs/app.log") # deliberately UNLABELED path
        time_cls = i.get_global("Time").as_rclass
        now = Value.robject(TimeObject.new(time_cls, ::Time.local))
        Legate::Entry.build(i, cls, path, :file, 2048_i64, now, label)
      end

      i.define_native("labeled_match") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Match").value].as_rclass
        path_cls = legate.constants[i.symbols.intern("Path").value].as_rclass
        path = Legate::Path.from_string(i, path_cls, "logs/app.log")
        Legate::Match.build(i, cls, path, 1_i64, "hit", ["before"], ["after"], label)
      end

      i.define_native("labeled_response") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Response").value].as_rclass
        Legate::Response.build(i, cls, 200, {"Content-Type" => "application/json"},
          Value.string(%({"a": 1}), label), "https://example.com", label)
      end

      i.define_native("labeled_exit") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Exit").value].as_rclass
        Legate::Exit.build(i, cls, 0, "secret output\n", "", false, 0.1, label)
      end
    end
    interp.modules.require("test/legate_ifc_triggers", interp)
    interp
  end

  # Same throwaway-TestStream pattern as `stream_spec.cr`, but feeding
  # PRE-LABELED Values through the source iterator, to verify Stream's
  # own terminals correctly join/propagate rather than launder.
  private def self.interp_with_labeled_stream_trigger : Interpreter
    interp, _ = make_interp
    interp.modules.register("test/legate_ifc_stream_trigger") do |i|
      legate = i.get_global("Legate").as_rclass
      stream_module = legate.constants[i.symbols.intern("Stream").value].as_rclass

      test_stream_cls = RubyClass.new("TestStream", nil, is_module: false)
      test_stream_cls.rclass = i.class_class
      test_stream_cls.included_modules << stream_module
      i.define_global_class(test_stream_cls)

      i.define_native("labeled_stream_of") do |args, _blk, _ncc|
        # Each element gets its OWN distinct origin, so a join-across-
        # elements bug (only picking up the LAST label, say) would be
        # distinguishable from a correct join in the resulting tags.
        values = args.each_with_index.map do |v, idx|
          Value.new(v.raw, RiskFlowLabel.of(ProvenanceKind::File, "/tainted/#{idx}", Sensitivity::High))
        end.to_a
        Value.robject(StreamObject.new(test_stream_cls, values.each))
      end
    end
    interp.modules.require("test/legate_ifc_stream_trigger", interp)
    interp
  end

  describe "Legate IFC label propagation" do
    describe "Legate::Path" do
      it "Path.new(tainted_string) does NOT launder the taint — the confirmed live bug this audit fixed" do
        interp = make_legate_ifc_interp
        result = interp.eval(%(Legate::Path.new(tainted_str("/etc/passwd"))))
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/passwd"
      end

      it "the label survives onto #to_s" do
        interp = make_legate_ifc_interp
        result = interp.eval(%(Legate::Path.new(tainted_str("/etc/passwd")).to_s))
        result.label.not_nil!.tags.first.origin.should eq "/etc/passwd"
      end

      it "the label survives onto #basename/#ext/#stem" do
        interp = make_legate_ifc_interp
        interp.eval(%(Legate::Path.new(tainted_str("/etc/passwd")).basename)).label.should_not be_nil
        interp.eval(%(Legate::Path.new(tainted_str("/etc/passwd")).ext)).label.should_not be_nil
        interp.eval(%(Legate::Path.new(tainted_str("/etc/passwd")).stem)).label.should_not be_nil
      end

      it "the label survives onto #parts and its elements" do
        interp = make_legate_ifc_interp
        result = interp.eval(%(Legate::Path.new(tainted_str("/etc/passwd")).parts))
        result.label.should_not be_nil
        result.as_array.to_a.first.label.should_not be_nil
      end

      it "#absolute? and #under? stay unlabeled — metadata, not extracted data (deliberate, not an oversight)" do
        interp = make_legate_ifc_interp
        interp.eval(%(Legate::Path.new(tainted_str("/etc/passwd")).absolute?)).label.should be_nil
        interp.eval(<<-RUBY).label.should be_nil
        Legate::Path.new(tainted_str("/etc/passwd")).under?(Legate::Path.new("/etc"))
        RUBY
      end

      it "#/ joins BOTH operands' labels — matches the arithmetic-ops \"combine, don't pick one side\" rule" do
        interp = make_legate_ifc_interp
        result = interp.eval(<<-RUBY)
        Legate::Path.new(tainted_str("/etc/passwd")) / tainted_str("shadow")
        RUBY
        label = result.label.not_nil!
        label.tags.size.should eq 2
      end

      it "an untainted Path stays unlabeled — the fix doesn't over-taint" do
        interp = make_legate_ifc_interp
        interp.eval(%(Legate::Path.new("logs/app.log"))).label.should be_nil
      end
    end

    describe "Legate::Stat/Entry/Match/Response/Exit — broker-side .build propagation" do
      it "Stat: size and the outer object carry the label; type/mode (metadata) don't" do
        interp = interp_with_labeled_value_triggers
        result = interp.eval("labeled_stat")
        result.label.should_not be_nil
        interp.eval("labeled_stat.size").label.should_not be_nil
        interp.eval("labeled_stat.type").label.should be_nil
        interp.eval("labeled_stat.mode").label.should be_nil
      end

      it "Entry: the explicit label joins with the (here, unlabeled) path's own label" do
        interp = interp_with_labeled_value_triggers
        interp.eval("labeled_entry").label.should_not be_nil
        interp.eval("labeled_entry.size").label.should_not be_nil
        interp.eval("labeled_entry.type").label.should be_nil
      end

      it "Match: text/before/after carry the label; line_no (metadata) doesn't" do
        interp = interp_with_labeled_value_triggers
        interp.eval("labeled_match.text").label.should_not be_nil
        interp.eval("labeled_match.before").label.should_not be_nil
        interp.eval("labeled_match.before").as_array.to_a.first.label.should_not be_nil
        interp.eval("labeled_match.line_no").label.should be_nil
      end

      it "Response: header VALUES and the outer object carry the label; status/url don't" do
        interp = interp_with_labeled_value_triggers
        interp.eval("labeled_response").label.should_not be_nil
        interp.eval(%(labeled_response.headers["content-type"])).label.should_not be_nil
        interp.eval("labeled_response.status").label.should be_nil
        interp.eval("labeled_response.url").label.should be_nil
      end

      it "Response#json propagates the body's own label onto every piece of the decoded structure" do
        interp = interp_with_labeled_value_triggers
        interp.eval(%(labeled_response.json["a"])).label.should_not be_nil
        interp.eval("labeled_response.json").label.should_not be_nil
      end

      it "Exit: out/err and the outer object carry the label; code/truncated/duration don't" do
        interp = interp_with_labeled_value_triggers
        interp.eval("labeled_exit").label.should_not be_nil
        interp.eval("labeled_exit.out").label.should_not be_nil
        interp.eval("labeled_exit.code").label.should be_nil
        interp.eval("labeled_exit.duration").label.should be_nil
      end
    end

    describe "Legate::Stream" do
      it "map passes through whatever label the invoked block's own return value carries — ordinary VM propagation, nothing Stream-specific to break" do
        interp = interp_with_labeled_stream_trigger
        result = interp.eval("labeled_stream_of(1).map { |x| x + 1 }.first")
        result.label.should_not be_nil
      end

      it "to_a's container label joins across every collected element (distinct origins, to catch a \"just takes the last one\" bug)" do
        interp = interp_with_labeled_stream_trigger
        result = interp.eval("labeled_stream_of(1, 2, 3).to_a")
        label = result.label.not_nil!
        label.tags.map(&.origin).to_set.should eq Set{"/tainted/0", "/tainted/1", "/tainted/2"}
      end

      it "first(n)'s container label joins the same way, but only across the n elements actually taken" do
        interp = interp_with_labeled_stream_trigger
        result = interp.eval("labeled_stream_of(1, 2, 3).first(2)")
        label = result.label.not_nil!
        label.tags.map(&.origin).to_set.should eq Set{"/tainted/0", "/tainted/1"}
      end

      it "sum's result joins every summed element's label" do
        interp = interp_with_labeled_stream_trigger
        result = interp.eval("labeled_stream_of(1, 2, 3).sum")
        label = result.label.not_nil!
        label.tags.size.should eq 3
      end

      it "select/reject filtering doesn't affect propagation of what survives" do
        interp = interp_with_labeled_stream_trigger
        result = interp.eval("labeled_stream_of(1, 2, 3, 4).select { |x| x.even? }.to_a")
        label = result.label.not_nil!
        label.tags.map(&.origin).to_set.should eq Set{"/tainted/1", "/tainted/3"}
      end
    end
  end
end
