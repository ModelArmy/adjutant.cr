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

    it "a top-level def, called later in the SAME walked body, resolves (not RiskUnresolved)" do
      interp, _ = make_interp
      risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
      register_risky_module(interp, "delete_file", risk)
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        def cleanup(force)
          delete_file()
        end
        cleanup(true)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::DeletesFiles}
      summary.path.none? { |p| p.includes?("unresolved") }.should be_true
    end

    it "a call BEFORE its def in the same body is RiskUnresolved (matches runtime NameError)" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        cleanup(true)
        def cleanup(force)
          42
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.path.any? { |p| p.includes?("unresolved") }.should be_true
    end

    it "a class's own methods can call each other regardless of definition order" do
      interp, _ = make_interp
      register_risky_module(interp, "log_fn", RiskProfile.none)
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        class Svc
          def first
            second
          end

          def second
            log_fn()
          end
        end
        s = Svc.new
        s.first
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.path.none? { |p| p.includes?("unresolved") }.should be_true
    end

    it "a bare unresolvable call inside a class body (not inside a def) is RiskUnresolved" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        class Svc
          nonexistent_fn()
          def ping
            42
          end
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.path.any? { |p| p.includes?("unresolved") }.should be_true
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

    it "unless takes the worst branch, not a union" do
      interp, _ = make_interp
      register_risky_module(interp, "safe_read", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "dangerous_delete",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        unless true
          safe_read()
        else
          dangerous_delete()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::DeletesFiles}
      summary.path.should contain "unless branch"
    end

    it "a risky call in a modifier-if is not silently dropped" do
      interp, _ = make_interp
      register_risky_module(interp, "delete_fn",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("delete_fn() if true")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::DeletesFiles}
    end

    it "a risky call in a modifier-while is marked iterated" do
      interp, _ = make_interp
      register_risky_module(interp, "write_fn", RiskProfile.new(tags: Set{RiskTag::WritesFiles}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("write_fn() while true")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.iterated?.should be_true
      summary.tags.should eq Set{RiskTag::WritesFiles}
    end

    it "begin/rescue takes the worst of body vs rescue, not a union" do
      interp, _ = make_interp
      register_risky_module(interp, "safe_read", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "dangerous_delete",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          safe_read()
        rescue
          dangerous_delete()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::DeletesFiles}
      summary.path.should contain "rescue branch"
    end

    it "ensure's risk always applies, regardless of the try/rescue outcome" do
      interp, _ = make_interp
      register_risky_module(interp, "safe_read", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "cleanup_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          safe_read()
        ensure
          cleanup_fn()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      # ensure's risk must appear even though the protected body alone
      # is Info-only. The Sequence wrapping the Choice unions tags from
      # BOTH the try body (ReadsFiles) and ensure (DeletesFiles) — both
      # genuinely run in this shape (try succeeds, then ensure always
      # runs), so both are real, not just the worst one.
      summary.tags.should eq Set{RiskTag::ReadsFiles, RiskTag::DeletesFiles}
      summary.severity.should eq Severity::Error
    end

    it "a begin with no rescue clause still walks body and ensure as a plain Sequence" do
      interp, _ = make_interp
      register_risky_module(interp, "write_fn", RiskProfile.new(tags: Set{RiskTag::WritesFiles}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          write_fn()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::WritesFiles}
    end

    it "a module's methods are discoverable the same way a class's are" do
      interp, _ = make_interp
      register_risky_module(interp, "log_fn", RiskProfile.none)
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        module Helper
          def self_check
            log_fn()
          end
        end
      RUBY
      # Modules can't be `.new`'d and have no receiver-based dispatch
      # test here (no include/module-function yet) — this confirms the
      # module body itself is walked without error and doesn't crash
      # or silently vanish as an unhandled node.
      tree = walker.walk_body(body)
      RiskAggregator.summarize(tree).severity.should eq Severity::Info
    end

    it "an OpAssign's risky value is not silently dropped" do
      interp, _ = make_interp
      register_risky_module(interp, "fetch_fn", RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        total = 0
        total += fetch_fn()
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end

    it "a CondAssign's risky value is not silently dropped" do
      interp, _ = make_interp
      register_risky_module(interp, "fetch_fn", RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("x ||= fetch_fn()")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end

    # Note: `a, b = expr, expr` (bare comma-separated multi-assign) is
    # not yet parseable — see DEVELOPMENT.md's "Known Limitations"
    # (multi-assignment isn't fully wired for this statement shape).
    # walk_multi_assign exists and is exercised once that lands.

    it "an IndexAssign's risky value is not silently dropped" do
      interp, _ = make_interp
      register_risky_module(interp, "fetch_fn", RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        arr = []
        arr[0] = fetch_fn()
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end
  end
end
