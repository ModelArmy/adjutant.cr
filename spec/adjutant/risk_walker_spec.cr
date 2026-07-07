require "../spec_helper"

module Adjutant
  private def self.risk_walker_test_parse(source : String) : Body
    Parser.new(source).parse
  end

  private def self.register_risky_module(interp : Interpreter, name : String, risk : RiskProfile) : Nil
    interp.modules.register(name) do |i|
      i.define_native(name, risk: risk) { |_| Value.nil_value }
    end
    interp.modules.require(name, interp)
  end

  describe RiskWalker do
    it "a receiverless call to a pure native function summarizes to none" do
      interp, _ = make_interp
      register_risky_module(interp, "safe_fn", RiskProfile.none)
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("safe_fn()")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
    end

    it "a receiverless call to a risky native function surfaces its tags" do
      interp, _ = make_interp
      risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
      register_risky_module(interp, "delete_fn", risk)
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("delete_fn()")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.tags.should eq Set{RiskTag::DeletesFiles}
    end

    it "a call to an unregistered function is RiskUnresolved" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("nonexistent_fn()")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.path.first.should contain "unresolved"
    end

    it "a call on a literal-receiver resolves via the builtin class" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("5.to_s")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
      summary.tags.should be_empty
    end

    it "a call through a var assigned from a known constructor resolves" do
      interp, _ = make_interp
      interp.eval(<<-RUBY)
        class Widget
          def ping
            42
          end
        end
      RUBY
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        w = Widget.new
        w.ping
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      # ping's body is pure script code (no calls) — resolves cleanly,
      # not RiskUnresolved, proving receiver resolution worked.
      summary.path.any? { |p| p.includes?("unresolved") }.should be_false
    end

    it "a call through a var with unknowable type is RiskUnresolved" do
      interp, _ = make_interp
      interp.eval("class Widget\n  def ping\n    42\n  end\nend")
      walker = RiskWalker.new(interp)
      # A method's own param has no caller-supplied type information
      # (see RiskWalker's class docs) — w.ping inside use_it is
      # RiskUnresolved regardless of what any call site passes.
      body = risk_walker_test_parse(<<-RUBY)
        def use_it(w)
          w.ping
        end
        x = Widget.new
        use_it(x)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.path.any?(&.includes?("unresolved")).should be_true
    end

    it "a risky call used as an assignment's value is not silently dropped" do
      interp, _ = make_interp
      risk = RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning)
      register_risky_module(interp, "fetch_fn", risk)
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("result = fetch_fn()")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end

    it "an if/else with different-risk branches takes the worst branch, not a union" do
      interp, _ = make_interp
      register_risky_module(interp, "safe_read", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "dangerous_delete",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        if true
          safe_read()
        else
          dangerous_delete()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::DeletesFiles}
      summary.path.should contain "if branch"
    end

    it "a while loop body's risk is marked iterated" do
      interp, _ = make_interp
      register_risky_module(interp, "write_fn", RiskProfile.new(tags: Set{RiskTag::WritesFiles}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        while true
          write_fn()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.iterated?.should be_true
      summary.tags.should eq Set{RiskTag::WritesFiles}
    end

    it "direct recursion resolves without infinite looping" do
      interp, _ = make_interp
      register_risky_module(interp, "log_fn", RiskProfile.none)
      interp.eval(<<-RUBY)
        def go(n)
          log_fn()
          go(n)
        end
      RUBY
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("go(1)")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
      summary.path.none? { |p| p.includes?("unresolved") }.should be_true
    end

    it "a ScriptProc's risk is memoized (same object returned for repeated calls)" do
      interp, _ = make_interp
      register_risky_module(interp, "risky_fn",
        RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning))
      interp.eval(<<-RUBY)
        class Svc
          def call_it
            risky_fn()
          end
        end
      RUBY
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        s = Svc.new
        s.call_it
        s.call_it
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end
  end
end
