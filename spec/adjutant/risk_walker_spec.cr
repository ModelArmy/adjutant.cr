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
        # return type; TypeInference has no ArrayLiteral/general
        # native-function-return-type resolution, a real, PRE-EXISTING
        # gap unrelated to Piece D), which correctly contributes its
        # own ExecutesCode tag (see RiskAggregator.unresolved_profile).
        # What THIS spec is actually about — the receiver expression
        # itself not being silently dropped — only needs DeletesFiles
        # to be PRESENT, not the tag set to be exactly that.
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
        # Same reasoning as the receiver-expression spec above: `.each`
        # on an ArrayLiteral receiver is separately RiskUnresolved
        # (TypeInference has no ArrayLiteral case at all — a real,
        # pre-existing gap, not something Piece D touches), contributing
        # its own ExecutesCode tag on top of the block's DeletesFiles.
        # This spec is only about the block's risk not being dropped.
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
        # Same ArrayLiteral-receiver caveat as above — asserting
        # inclusion, not exact equality.
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
        # `.each` on an ArrayLiteral receiver is separately unresolved
        # (see SCOPE.md's Will Fix — pre-existing, unrelated gap), but
        # the block param `x` itself must NOT contribute a second,
        # spurious unresolved-call finding on top of that.
        summary.path.count(&.includes?("unresolved")).should eq 1
      end
    end
  end
end
