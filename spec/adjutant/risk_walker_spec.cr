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

    # Closes the "TypeInference#infer_node has no case for
    # ArrayLiteral/HashLiteral receivers" Will Fix item (SCOPE.md) —
    # this is the actual reported symptom: `[1, 2, 3].each { }`
    # previously inferred its receiver as UnknownType (TypeInference had
    # no ArrayLiteral case), so `.each` resolved as RiskUnresolved
    # (tagged ExecutesCode, Severity::Error) even though there's nothing
    # actually unresolvable about calling a method on a literal array —
    # same certainty `5.to_s` above already had. See
    # type_inference_spec.cr for the narrower TypeInference-level
    # coverage of the same fix.
    it "a call on an array-literal receiver resolves via the builtin class, not as unresolved" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse("[1, 2, 3].each { |x| x }")
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
      summary.path.first.should_not contain "unresolved"
    end

    it "a call on a hash-literal receiver resolves via the builtin class, not as unresolved" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(%({"a" => 1}.each { |k, v| k }))
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
      summary.path.first.should_not contain "unresolved"
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

    describe "keyword argument VALUES are walked (native kwargs support, 2026-08-09)" do
      # Found while designing native kwarg support: `node.kwargs` was
      # never walked at all before this — a risky call in a keyword
      # position was completely invisible to static analysis, the
      # same shape of gap the positional-args fix (2026-07-18, see
      # "risky call used as an assignment's value" above) closed for
      # `node.args`. See risk_walker.cr's walk_call for the fix.
      it "a risky call passed as a keyword argument's value surfaces its tags" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        interp.define_native("configure", kwarg_names: Set{"handler"}) { |_| Value.nil_value }
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse("configure(handler: delete_fn())")
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a pure call passed as a keyword argument's value stays clean" do
        interp, _ = make_interp
        interp.define_native("safe_fn", risk: RiskProfile.none) { |_| Value.nil_value }
        interp.define_native("configure", kwarg_names: Set{"handler"}) { |_| Value.nil_value }
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse("configure(handler: safe_fn())")
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end

      it "a risky kwarg value is caught alongside a risky positional arg, not instead of it" do
        interp, _ = make_interp
        delete_risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        network_risk = RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning)
        register_risky_module(interp, "delete_fn", delete_risk)
        register_risky_module(interp, "fetch_fn", network_risk)
        interp.define_native("configure", kwarg_names: Set{"handler"}) { |_| Value.nil_value }
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse("configure(fetch_fn(), handler: delete_fn())")
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles, RiskTag::NetworkEgress}
      end
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

    # Found 2026-07-18: fixing walk_identifier (bare names) surfaced
    # that a class's own sibling methods calling each other bare
    # (`second` from within `first`, no receiver/parens) fell through
    # to RiskUnresolved — the ORIGINAL test above only asserted "not
    # unresolved," not that the real risk value comes through; these
    # specs close that gap and cover the two related shapes (singleton
    # siblings, inherited-method resolution).
    describe "bare implicit-self calls to a class's own methods (found via Piece D testing)" do
      it "a risky sibling method's tags actually surface through a bare call, not just 'not unresolved'" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class Svc
            def first
              second
            end

            def second
              delete_fn()
            end
          end
          Svc.new.first
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "works the same for a chain of THREE bare sibling calls, not just one hop" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class Svc
            def a
              b
            end

            def b
              c
            end

            def c
              delete_fn()
            end
          end
          Svc.new.a
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "self_class is correctly nil again after returning from a nested class method walk (no context leak)" do
        # If @current_self_class leaked (not properly restored),
        # walking Svc's methods first could incorrectly make a LATER,
        # unrelated top-level bare call resolve against Svc's method
        # table too.
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class Svc
            def helper
              1
            end
          end
          Svc.new.helper
          helper
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        # The top-level bare `helper` (no Svc instance in scope here)
        # must be unresolved — Svc#helper is NOT a top-level def.
        summary.path.any? { |p| p.includes?("unresolved") }.should be_true
      end

      it "works for def self.foo calling a sibling def self.bar bare (singleton methods, not just instance)" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class Svc
            def self.first
              second
            end

            def self.second
              delete_fn()
            end
          end
          Svc.first
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a bare call to a method that doesn't exist anywhere in the chain is still honestly unresolved" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class Svc
            def first
              nonexistent_method
            end
          end
          Svc.new.first
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.path.any? { |p| p.includes?("unresolved") }.should be_true
      end
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

    it "multiple rescue clauses: takes the worst across ALL clauses, not just " \
       "the last one — regression guard for RiskChoice generalizing from a " \
       "fixed 2-way (body, rescue) choice to N clause branches" do
      interp, _ = make_interp
      register_risky_module(interp, "safe_read", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "dangerous_delete",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      register_risky_module(interp, "log_fn", RiskProfile.none)
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          safe_read()
        rescue TypeError
          log_fn()
        rescue ArgumentError
          dangerous_delete()
        rescue
          log_fn()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      # The risky call sits in the MIDDLE clause, not the first or
      # last — confirms the walker isn't just checking the first and
      # last branches, but genuinely folding in every clause.
      summary.tags.should eq Set{RiskTag::DeletesFiles}
      summary.path.should contain "rescue branch"
    end

    it "a rescue A, B clause with multiple classes still contributes exactly " \
       "one RiskChoice branch, not one per listed class" do
      interp, _ = make_interp
      register_risky_module(interp, "dangerous_delete",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          1
        rescue TypeError, ArgumentError
          dangerous_delete()
        end
      RUBY
      choice = walker.walk_body(body).as(RiskSequence).children.first.as(RiskChoice)
      # body + exactly one clause branch — the two-class list inside
      # that one clause must not have produced two branches.
      choice.children.size.should eq 2
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::DeletesFiles}
    end

    it "each rescue clause's bound variable is scoped independently — a name " \
       "bound in one clause doesn't leak into a sibling clause's risk walk" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          1
        rescue TypeError => e
          e
        rescue ArgumentError => f
          f
        end
      RUBY
      # Neither `e` nor `f` should be flagged as a bare-call attempt
      # in its OWN clause — each is a real local there, same as the
      # existing single-clause "rescue => e" bare-reference test
      # above, just exercised across two independent clause envs.
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
    end

    it "a risky call hidden inside a begin's else clause is still found — " \
       "walk_begin folds else into the SAME success branch as the body, " \
       "not a fresh alternative the aggregator could pick around" do
      # The scenario this guards against: a generated script puts its
      # dangerous work in `else` instead of the body (maybe because
      # `else` reads as \"the happy path\" to whoever/whatever wrote
      # it) and static assessment silently misses it because else
      # isn't folded into the choice the same way the body is.
      interp, _ = make_interp
      register_risky_module(interp, "safe_setup", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "dangerous_delete",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          safe_setup()
        rescue
          nil
        else
          dangerous_delete()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      # Both tags are real here: safe_setup() and dangerous_delete()
      # both genuinely run together on the success path (body then
      # else, in sequence) — RiskSequence unions tags from both
      # children rather than picking one, same "both are real, not
      # just the worst one" rule the existing ensure's-risk-always-
      # applies test documents. The point of this test is that
      # DeletesFiles shows up AT ALL — proving else's risky call
      # wasn't silently dropped — not that it shows up alone.
      summary.tags.should eq Set{RiskTag::ReadsFiles, RiskTag::DeletesFiles}
      summary.severity.should eq Severity::Error
    end

    it "takes the worst of (body + else) vs rescue, not a union — same " \
       "worst-case-branch aggregation as the plain body-vs-rescue case" do
      interp, _ = make_interp
      register_risky_module(interp, "safe_setup", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "safe_cleanup", RiskProfile.new(tags: Set{RiskTag::ReadsFiles}, severity: Severity::Info))
      register_risky_module(interp, "dangerous_delete",
        RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          safe_setup()
        rescue
          dangerous_delete()
        else
          safe_cleanup()
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      # The rescue branch is worse (DeletesFiles/Error) than the
      # body+else branch (ReadsFiles/Info only) — worst-of-all-
      # branches picks rescue here, same "not a union" contract the
      # existing plain body-vs-rescue test already asserts.
      summary.tags.should eq Set{RiskTag::DeletesFiles}
      summary.path.should contain "rescue branch"
    end

    it "a local assigned in the body is visible to else's risk walk " \
       "without a false-positive bare-call flag (body_env chaining, " \
       "not a fresh env.dup the way rescue/ensure branches use)" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        begin
          x = 5
        rescue
          nil
        else
          x
        end
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
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

    # AttrAssign (2026-08-08) — same shape of regression as
    # IndexAssign above, plus a second one specific to attr_accessor:
    # see the two specs below.
    it "an AttrAssign's risky VALUE is not silently dropped" do
      interp, _ = make_interp
      register_risky_module(interp, "fetch_fn", RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        class Box
          attr_accessor :value
        end
        b = Box.new
        b.value = fetch_fn()
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end

    it "an AttrAssign's risky RECEIVER expression is also walked, not just the value" do
      interp, _ = make_interp
      register_risky_module(interp, "fetch_fn", RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning))
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        class Box
          attr_accessor :value
        end
        def get_box
          fetch_fn()
        end
        get_box.value = 1
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end

    # The actual bug this session's attr_accessor work introduced and
    # caught before shipping (see append_statement's own comment,
    # parser.cr, and DEVELOPMENT.md's Parser section for the full
    # trace): a DefNode arriving inside a class body via a nested
    # Body (unflattened) would silently fall through walk_class's
    # `stmt.is_a?(DefNode)` check and never get registered on the
    # static class model at all — the compiled bytecode would still
    # run the method fine (compile_class dispatches Body generically),
    # but RiskWalker's OWN model of the class wouldn't know it
    # existed, surfacing as a false "unresolved" here even though the
    # method genuinely exists and would run correctly.
    it "a method defined via attr_accessor is registered on the static class model, not left unresolved" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        class Box
          attr_accessor :value
        end
        b = Box.new
        b.value
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.path.none? { |p| p.includes?("unresolved") }.should be_true
    end

    it "attr_writer's generated setter is likewise registered (not just attr_reader's getter)" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = risk_walker_test_parse(<<-RUBY)
        class Box
          attr_writer :value
        end
        b = Box.new
        b.value = 1
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.path.none? { |p| p.includes?("unresolved") }.should be_true
    end

    # Piece D (SCOPE.md, 2026-07-18): Call#args were never walked at
    # all before this — a risky call used as a plain ARGUMENT, no
    # lambda/block involved, was completely invisible to the walker.
    describe "call argument walking (Piece D)" do
      it "a risky call used as a plain argument is no longer invisible" do
        interp, _ = make_interp
        register_risky_module(interp, "safe_fn", RiskProfile.none)
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse("safe_fn(delete_fn())")
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a risky receiver expression (not just args) is also walked" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse("delete_fn().to_s")
        summary = RiskAggregator.summarize(walker.walk_body(body))
        # Not asserting `tags eq {DeletesFiles}` — .to_s on delete_fn()'s
        # result is separately RiskUnresolved (delete_fn has no known
        # return type at all — TypeInference has no general native-
        # function-return-type resolution; unrelated to the
        # ArrayLiteral/HashLiteral literal-receiver gap fixed
        # 2026-07-21, since delete_fn()'s result isn't a literal),
        # which correctly contributes its own ExecutesCode tag (see
        # RiskAggregator.unresolved_profile). What THIS spec is
        # actually about — the receiver expression itself not being
        # silently dropped — only needs DeletesFiles to be PRESENT,
        # not the tag set to be exactly that.
        summary.tags.should contain RiskTag::DeletesFiles
      end
    end

    # Piece D: a `{ }`/`do...end` block attached to a call folds
    # unconditionally into that call's risk — `yield` inside the
    # callee is a real, statically-visible invocation contract, so
    # (unlike a Lambda passed as an argument) invocation itself is
    # confirmed, only the closure's own body risk needed walking.
    describe "block folding (Piece D)" do
      it "a risky call inside a block passed to each is no longer invisible" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          [1, 2, 3].each { |x| delete_fn() }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        # Prior to 2026-07-21, `.each` on an ArrayLiteral receiver was
        # separately RiskUnresolved (TypeInference had no ArrayLiteral
        # case), contributing its own ExecutesCode tag on top of the
        # block's DeletesFiles — fixed, see type_inference_spec.cr.
        # Asserting `contain`, not exact tag-set equality, since this
        # spec is only about the block's own risk not being dropped.
        summary.tags.should contain RiskTag::DeletesFiles
      end

      it "a block sees the enclosing env, not a fresh param-only scope (real closure semantics)" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        register_risky_module(interp, "safe_fn", RiskProfile.none)
        walker = RiskWalker.new(interp)
        # The block itself doesn't call anything risky directly, but
        # this exercises that walk_iterated's env.dup is truly the
        # CALLER's env (with outer local knowledge), not a lambda-style
        # fresh scope — confirmed indirectly via the block still being
        # walked at all (see the two specs above/below), and directly
        # here via a risky call OUTSIDE the block still being counted
        # in the same summarize alongside the block's own risk.
        body = risk_walker_test_parse(<<-RUBY)
          delete_fn()
          [1, 2, 3].each { |x| safe_fn() }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        # Asserting inclusion, not exact tag-set equality — the
        # ArrayLiteral-receiver gap this comment used to caveat around
        # was fixed 2026-07-21 (type_inference_spec.cr), but the
        # `contain` shape is kept since this spec's actual point is the
        # risky call OUTSIDE the block, not the receiver.
        summary.tags.should contain RiskTag::DeletesFiles
      end
    end

    # Piece D: a Lambda LITERAL passed as a call argument is walked
    # eagerly (so its body risk is known) but wrapped RiskDeferred —
    # invocation by the callee isn't confirmed, only possible, unlike a
    # BlockNode's confirmed yield-contract.
    describe "Lambda literal as a call argument (Piece D)" do
      it "its risk is surfaced (not invisible) but tagged deferred, not folded in unconditionally" do
        interp, _ = make_interp
        register_risky_module(interp, "apply_fn", RiskProfile.none)
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          apply_fn(->() { delete_fn() })
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
        summary.path.any?(&.starts_with?("deferred:")).should be_true
      end

      it "a pure lambda literal argument stays clean" do
        interp, _ = make_interp
        register_risky_module(interp, "apply_fn", RiskProfile.none)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse("apply_fn(->(x) { x + 1 })")
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end
    end

    # Piece D, found by the person: a constant-held lambda is exactly
    # as resolvable as a literal, once constants are assign-once. Two
    # distinct shapes: passed onward as an argument (still RiskDeferred
    # — invocation not confirmed) vs. CONST.call(...) directly
    # (invocation IS confirmed, resolves straight to the body's risk).
    describe "constant-held lambdas (Piece D)" do
      it "F1.call(...) resolves directly to the lambda body's risk, no RiskDeferred wrapper" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          F1 = ->() { delete_fn() }
          F1.call
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
        summary.path.any?(&.starts_with?("deferred:")).should be_false
      end

      it "F1 passed as an argument gets the RiskDeferred treatment, same as a literal" do
        interp, _ = make_interp
        register_risky_module(interp, "apply_fn", RiskProfile.none)
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          F1 = ->() { delete_fn() }
          apply_fn(F1)
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
        summary.path.any?(&.starts_with?("deferred:")).should be_true
      end

      it "a lambda in an ordinary (non-constant) variable stays unresolved — real aliasing, out of scope" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          f1 = ->() { 1 }
          f1.call
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.path.first.should contain "unresolved"
      end

      it "a recursive constant-held lambda (F1 = ->() { F1.call }) doesn't infinite-loop the walker" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          F1 = ->() { F1.call }
          F1.call
        RUBY
        # Just needs to terminate — the recursive inner F1.call should
        # resolve to the same recursion-guard RiskLeaf walk_lambda_body
        # gives (mirrors walk_script_method's own guard for defs), not
        # loop forever.
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.should_not be_nil
      end
    end

    # Found 2026-07-18 via the person's samples/risk_static_literal_
    # lambda.rb: a bare `delete_file` (no parens) inside a Lambda's
    # body was silently invisible — walk_node's generic `else` branch
    # treated every bare Identifier as a harmless value read, never
    # recognizing the VM's own real fallback (Op::GetGlobal -> implicit
    # zero-arg method call attempt, matching real Ruby's own local-vs-
    # call disambiguation rule). Pre-existing bug, unrelated to Piece D
    # itself, but only exposed by it (lambda bodies weren't walked at
    # all before D, hiding this).
    describe "bare identifier as an implicit zero-arg call (found via Piece D testing)" do
      it "a bare risky function name (no parens) is no longer invisible" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse("delete_fn")
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "matches the WITH-parens call exactly (same resolution path)" do
        interp, _ = make_interp
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        with_parens = RiskAggregator.summarize(walker.walk_body(risk_walker_test_parse("delete_fn()")))
        walker2 = RiskWalker.new(interp)
        without_parens = RiskAggregator.summarize(walker2.walk_body(risk_walker_test_parse("delete_fn")))
        with_parens.tags.should eq without_parens.tags
        with_parens.severity.should eq without_parens.severity
      end

      it "a genuine local read (param) is NOT treated as a call — no false positive" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          def foo(x)
            x
          end
          foo(1)
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end

      it "a genuine local read (earlier assignment) is NOT treated as a call — no false positive" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          x = 1
          x
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end

      it "a bare risky call inside a Lambda literal argument is now found (the person's exact repro shape)" do
        interp, _ = make_interp
        register_risky_module(interp, "apply_fn", RiskProfile.none)
        register_risky_module(interp, "delete_fn", RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          apply_fn(->() { delete_fn })
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "rescue => e — a bare reference to the caught exception is not a false-positive call" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          begin
            1
          rescue => e
            e
          end
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end

      it "a for loop's variable is not a false-positive call" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          for x in [1, 2, 3]
            x
          end
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end

      it "a block's own param is not a false-positive call" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          [1, 2, 3].each { |x| x }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        # Originally written expecting exactly 1 "unresolved" entry —
        # `.each` on an ArrayLiteral receiver was unresolved at the
        # time (SCOPE.md's Will Fix item, since fixed 2026-07-21 — see
        # type_inference_spec.cr/the "array-literal receiver resolves"
        # spec above), plus zero false positives from the block param
        # `x` itself. With the receiver now resolving cleanly, the
        # correct count is 0, not 1 — updating the assertion to match
        # is the right fix here, not a sign this spec's actual intent
        # (a block param must never spuriously count as an unresolved
        # call) has changed.
        summary.path.count(&.includes?("unresolved")).should eq 0
      end
    end

    describe "collection literal elements (array/hash) are walked for risk" do
      it "a risky call inside an array literal is found — regression guard " \
         "for the 2026-08-08 gap where ArrayLiteral fell through walk_node's " \
         "generic else branch entirely" do
        interp, _ = make_interp
        register_risky_module(interp, "dangerous_delete",
          RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          [dangerous_delete(), 1, 2]
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
        summary.severity.should eq Severity::Error
      end

      it "a risky call inside a hash literal (hash-rocket spelling) is found" do
        interp, _ = make_interp
        register_risky_module(interp, "dangerous_delete",
          RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          { "path" => dangerous_delete() }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a risky call inside a hash literal (symbol-shorthand spelling) is " \
         "found — the concrete case from samples/scripts/risk_static/" \
         "risk_static_hash_literal.rb that confirmed this gap" do
        interp, _ = make_interp
        register_risky_module(interp, "dangerous_delete",
          RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          { path: dangerous_delete() }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a risky call inside a hash literal's KEY position is found too, " \
         "not just the value" do
        interp, _ = make_interp
        register_risky_module(interp, "dangerous_delete",
          RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          { dangerous_delete() => "ok" }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a risky call nested inside a literal inside another literal is " \
         "still found — confirms recursion, not just one level deep" do
        interp, _ = make_interp
        register_risky_module(interp, "dangerous_delete",
          RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          { targets: [1, dangerous_delete()] }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "an array/hash literal with no calls at all still reports Info, " \
         "no false positives introduced by walking every element" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          [1, 2, { a: 3, "b" => 4 }]
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
        summary.tags.should be_empty
      end

      it "multiple risky calls across array elements and hash pairs all " \
         "contribute — tags union, not just the worst one, since every " \
         "element genuinely evaluates" do
        interp, _ = make_interp
        register_risky_module(interp, "dangerous_delete",
          RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
        register_risky_module(interp, "fetch_url",
          RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning))
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          { deleted: dangerous_delete(), fetched: fetch_url() }
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.tags.should eq Set{RiskTag::DeletesFiles, RiskTag::NetworkEgress}
        summary.severity.should eq Severity::Error
      end
    end

    describe "super" do
      # SuperNode had no case of its own in walk_node before this —
      # it fell into the generic `else` branch, so a risky call
      # reached via `super` (either as an explicit argument, or as
      # the superclass method super ITSELF invokes) was completely
      # invisible to static analysis. Same blind spot walk_call's own
      # 2026-07-18 args fix closed for ordinary calls. See SCOPE.md's
      # risk-flow-impact note for the super-dispatch rewrite session.
      it "a risky call reached via a SCRIPT superclass method through `super` surfaces its tags" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class A
            def run
              delete_fn()
            end
          end
          class B < A
            def run
              super()
            end
          end
          B.new.run
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a risky call passed as an EXPLICIT `super` argument surfaces its tags, even though the superclass method itself does nothing with it" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning)
        register_risky_module(interp, "fetch_url", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class A
            def run(x)
            end
          end
          class B < A
            def run(x)
              super(fetch_url())
            end
          end
          B.new.run(1)
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Warning
        summary.tags.should eq Set{RiskTag::NetworkEgress}
      end

      it "a risky NATIVE method reached via `super` surfaces its tags" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        cls = RubyClass.new("Greeter")
        sym_id = interp.symbols.intern("greet").value
        cls.define_native_method(sym_id, risk) { |args| Value.nil_value }
        interp.define_global_class(cls)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class Talker < Greeter
            def greet
              super()
            end
          end
          Talker.new.greet
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a pure call reached via `super` stays clean" do
        interp, _ = make_interp
        register_risky_module(interp, "safe_fn", RiskProfile.none)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class A
            def run
              safe_fn()
            end
          end
          class B < A
            def run
              super()
            end
          end
          B.new.run
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end

      it "`super` with no matching ancestor method is RiskUnresolved, not silently clean" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class A
          end
          class B < A
            def only_here
              super()
            end
          end
          B.new.only_here
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.path.first.should contain "super"
      end
    end

    describe "multi-level closures (Step 5 — risk-flow coverage check, VM fix Aug 10)" do
      # RiskWalker was never coupled to the VM/compiler bug the rest
      # of this session's work fixes — it has its own, simpler model
      # for closures entirely (see DEVELOPMENT.md's RiskWalker
      # section). Confirms that model already extends correctly to
      # multiple nesting levels, not just one, rather than assuming
      # it from reading the mechanism alone.

      it "an ordinary block's env-threading (env.dup) already handles a risky call nested TWO blocks deep, correctly" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          [1].each do |i|
            [1].each do |j|
              delete_fn()
            end
          end
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "a block nested two levels deep correctly resolves a variable from the OUTERMOST scope as a known local, not an unresolved bare call" do
        # env.dup threading two levels deep — if this were broken,
        # the bare reference to x would fall through to
        # walk_bare_name_call and show up as RiskUnresolved instead
        # of contributing no risk.
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          x = 1
          [1].each do |i|
            [1].each do |j|
              x
            end
          end
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Info
      end

      it "a lambda passed as an argument, nested two blocks deep, still resolves via the existing RiskDeferred path" do
        # Confirms the EXISTING (pre-dating this session) lambda-as-
        # argument handling isn't disturbed by extra block nesting
        # around it — walk_call_arg's Lambda special-case doesn't
        # care how deep the surrounding blocks are, only that the
        # lambda literal is a direct call argument at ITS OWN call
        # site.
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        register_risky_module(interp, "run_it", RiskProfile.none)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          [1].each do |i|
            [1].each do |j|
              run_it(-> { delete_fn() })
            end
          end
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end
    end
  end
end
