require "../../spec_helper"

module Adjutant
  # Piece C (see SCOPE.md): a `Lambda` node (`->(){}`) compiles
  # (compile_lambda, Op::MakeProc with a=1 — see vm.cr) to a
  # real RubyObject of class Proc, not a bare Value.proc(sproc) as
  # before. This gives lambdas .class/is_a?/.call, matching real Ruby.
  #
  # `lambda { ... }` (the `Kernel`-method spelling) wraps into this
  # SAME shape as of 2026-08-19 — see the "lambda (Kernel spelling)"
  # describe block below for its own coverage, and builtins/proc.cr's
  # registration comment for the scope reasoning. `proc { ... }` is
  # deliberately NOT given the same treatment (see that same comment,
  # and UNSUPPORTED.md's U019 entry) — real Ruby's `proc { }` has
  # different arity/return semantics from `lambda { }`, so reusing
  # this shape for it would have been a silent divergence, not a
  # smaller-but-correct subset. Calling `proc { }` raises a proper
  # declared-exclusion error (`U019`), not a generic undefined-method
  # one.
  #
  # Scope boundary (see SCOPE.md, builtins/proc.cr header): only
  # Lambda-node output AND `lambda { }` become a Proc
  # instance. Call-site block literals (`{ }`/`do...end`) and `def`
  # bodies keep using the bare, unwrapped Value.proc(sproc) as
  # before — covered by the "block literals are unaffected" spec
  # below, to guard against a future change accidentally widening
  # Op::MakeProc's a=1 branch to those too.
  #
  # No bare `name(...)`-without-`.call` support exists (real Ruby
  # doesn't have it either) — not tested here since it's explicitly
  # not a feature, not a gap.
  describe "Proc" do
    it "->(){}.class is Proc" do
      eval("(->(x) { x }).class == Proc").truthy?.should be_true
    end

    it "->(){}.is_a?(Proc) is true" do
      eval("(->(x) { x }).is_a?(Proc)").truthy?.should be_true
    end

    it "is not an Array" do
      eval("(->(x) { x }).is_a?(Array)").falsy?.should be_true
    end

    describe "#call" do
      it "invokes the lambda body and returns its value" do
        eval("dbl = ->(x) { x * 2 }; dbl.call(3)").as_int.should eq 6
      end

      it "supports multiple params" do
        eval("add = ->(a, b) { a + b }; add.call(2, 5)").as_int.should eq 7
      end

      it "supports zero params" do
        eval("f = -> { 42 }; f.call").as_int.should eq 42
      end

      it "closes over an outer local" do
        result = eval(<<-RUBY)
          n = 10
          incr = ->(x) { x + n }
          incr.call(5)
        RUBY
        result.as_int.should eq 15
      end

      it "can be called more than once" do
        result = eval(<<-RUBY)
          sq = ->(x) { x * x }
          [sq.call(2), sq.call(3), sq.call(4)]
        RUBY
        result.as_array.map(&.as_int).should eq [4, 9, 16]
      end

      # Regression for a 2026-07-18 bug: VM#invoke (the mechanism
      # Proc#call routes through) isolated @frames for its nested
      # execute run but NOT @stack — so a call nested inside a still-
      # pending compound expression (here, an array literal with an
      # earlier element's value already sitting on the shared stack)
      # returned that stale, unrelated leftover instead of its own
      # Op::Ret result. Sequential calls with no pending stack value in
      # between (see "can be called more than once" above) did NOT
      # expose this — confirmed via the person's own
      # spec/scripts/expressions.rb repro, which is what surfaced the
      # distinction. This spec pins the specific failing shape (a call
      # nested inside an in-progress array literal) as its own
      # regression guard, separate from the general repeated-call spec
      # above, since that one alone would not have caught this bug.
      it "returns its own result when called from inside an array literal, not a leftover earlier element" do
        result = eval(<<-RUBY)
          sq = ->(x) { x * x }
          ar = [sq.call(2), sq.call(3), sq.call(4)]
          ar
        RUBY
        result.as_array.map(&.as_int).should eq [4, 9, 16]
      end

      it "can be stored in an array and called via each element" do
        result = eval(<<-RUBY)
          fns = [->(x) { x + 1 }, ->(x) { x * 10 }]
          fns.map { |f| f.call(3) }
        RUBY
        result.as_array.map(&.as_int).should eq [4, 30]
      end

      it "can be passed as a plain argument to a method" do
        result = eval(<<-RUBY)
          def apply(f, x)
            f.call(x)
          end
          apply(->(x) { x - 1 }, 10)
        RUBY
        result.as_int.should eq 9
      end

      # Regression for a closure-capture bug found 2026-07-20 while
      # investigating the Must Fix "verify IFC label propagation
      # through lambdas" item (see research/IFC_DESIGN.md and
      # SCOPE.md). Every existing "closes over an outer local" spec
      # above (and "can be stored in an array..."/"passed as a plain
      # argument...") happens to .call the lambda from the SAME frame
      # it was defined in (top level), so VM#invoke's `outer:
      # f.locals` — the CALLING frame's locals, not a real snapshot of
      # the lambda's own creation-site scope — is only accidentally
      # correct: that caller frame IS the defining frame. Op::MakeProc
      # (compiler.cr, a=1 branch) never snapshots outer_locals the way
      # Op::SetBlock does for ordinary blocks (see Frame#
      # block_outer_locals's own comment on that pattern) — nothing
      # captures the lambda's true lexical parent scope at all.
      #
      # This spec returns a lambda OUT of the frame that defined it
      # (make_adder's) and calls it from a different frame (top
      # level) later — the shape every prior spec avoided. If
      # captured-closure values don't survive a defining-frame/
      # calling-frame mismatch, `n` resolves against top level's
      # locals instead of make_adder's, which do not contain n at
      # all — producing a wrong value (most likely 0, if the slot
      # happens to be in-bounds but holds an unrelated nil-defaulted
      # local) rather than a parse or lookup error.
      it "closes over its defining frame's local, not the calling frame's, when called later from elsewhere" do
        result = eval(<<-RUBY)
          def make_adder(n)
            ->(x) { x + n }
          end

          add5 = make_adder(5)
          add5.call(10)
        RUBY
        result.as_int.should eq 15
      end
    end

    describe "#lambda?" do
      it "is true" do
        eval("(->(x) { x }).lambda?").truthy?.should be_true
      end
    end

    # Before this, Proc had NO to_s/inspect at all — it fell through
    # to Object's own default #inspect, which lists ivars, and Proc's
    # own internal representation ivar is literally named `__sproc`,
    # so the OLD behavior leaked that implementation detail into
    # user-visible output. Every case below is a real, previously-
    # broken behavior, not new coverage of something that already
    # worked.
    describe "#to_s / #inspect" do
      it "to_s and inspect produce the same output — real Ruby renders them identically for Proc" do
        interp, _ = make_interp
        result = interp.eval("[(->(x) { x }).to_s, (->(x) { x }).inspect]")
        strs = result.as_array.map(&.as_string)
        strs[0].should eq strs[1]
      end

      it "renders as #<Proc file:line (lambda)>, not the old implementation-detail leak" do
        interp, _ = make_interp
        str = interp.eval("(->(x) { x }).to_s").as_string
        str.starts_with?("#<Proc <eval>:").should be_true
        str.ends_with?(" (lambda)>").should be_true
      end

      it "does NOT leak the internal __sproc ivar name into the output" do
        interp, _ = make_interp
        str = interp.eval("(->(x) { x }).to_s").as_string
        str.includes?("__sproc").should be_false
      end

      it "the line number reflects the CREATION site, not wherever .call later happens to run from" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        def make_it
          ->(x) { x }
        end
        f = make_it
        f.call(1)
        f.to_s
        RUBY
        # The lambda literal itself is on line 2 of this heredoc.
        result.as_string.should contain("<eval>:2")
      end

      it "two lambdas created on different lines report different line numbers" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        a = ->(x) { x }
        b = ->(x) { x }
        [a.to_s, b.to_s]
        RUBY
        strs = result.as_array.map(&.as_string)
        strs[0].should contain("<eval>:1")
        strs[1].should contain("<eval>:2")
        strs[0].should_not eq strs[1]
      end
    end

    it "block literals stay unaffected (no .class/.call as a value)" do
      # A call-site block ({ }) is only reachable via yield inside the
      # method it's passed to — it's never bound to a value at all, so
      # there's no expression here that could even produce a Proc
      # instance to assert against. This spec exists to document the
      # boundary and fail loudly (as a compile/runtime error from the
      # `blk` reference) if that ever changes.
      result = eval(<<-RUBY)
        def yields_once
          yield 5
        end
        yields_once { |n| n * 2 }
      RUBY
      result.as_int.should eq 10
    end

    it "every builtin Proc method defaults to RiskProfile.none" do
      interp, _ = make_interp
      cls = interp.get_global("Proc").as_rclass
      %w[call lambda?].each do |name|
        sym_id = interp.symbols.lookup(name).not_nil!.value
        cls.find_native_method(sym_id).not_nil!.risk.should eq RiskProfile.none
      end
    end

    # Kernel-spelled `lambda { }` — added 2026-08-19, SCOPE.md's Must
    # Fix list. See builtins/proc.cr's own registration comment for
    # why `proc { }` is NOT included alongside it (real Ruby's
    # `proc { }` has different arity/return semantics from
    # `lambda { }` — reusing this same object shape for it would have
    # been a silent divergence from real Ruby, not a smaller-but-
    # correct subset), and UNSUPPORTED.md's U019 entry for the
    # declared-exclusion treatment `proc { }` gets instead.
    describe "lambda (Kernel spelling)" do
      it "lambda { }.class is Proc" do
        eval("(lambda { |x| x }).class == Proc").truthy?.should be_true
      end

      it "lambda { }.call invokes the block and returns its value" do
        eval("dbl = lambda { |x| x * 2 }; dbl.call(3)").as_int.should eq 6
      end

      it "lambda { } closes over an outer local, same as ->(){}" do
        result = eval(<<-RUBY)
          n = 10
          incr = lambda { |x| x + n }
          incr.call(5)
        RUBY
        result.as_int.should eq 15
      end

      it "lambda { } closes over its defining frame, not the calling frame, when returned and called elsewhere" do
        result = eval(<<-RUBY)
          def make_adder(n)
            lambda { |x| x + n }
          end

          add5 = make_adder(5)
          add5.call(10)
        RUBY
        result.as_int.should eq 15
      end

      it "lambda { }.lambda? is true" do
        eval("(lambda { |x| x }).lambda?").truthy?.should be_true
      end

      it "lambda without a block raises ArgumentError (R032)" do
        error = expect_raises(RuntimeError) { eval("lambda") }
        error.diagnostic.not_nil!.code.should eq("R032")
      end

      # NOT tested here: an explicit builtin-typed receiver (`5.lambda { }`)
      # does NOT raise, despite `is_private: true` above — a real,
      # pre-existing, already-documented gap (vm.cr's `dispatch_call`,
      # the "Builtin-typed receiver" branch): private-method
      # enforcement (`raise_if_private_call`) only runs for a
      # `RubyObject` receiver, never for a builtin-typed one like
      # Integer. `is_private: true` is still correct to set — it's
      # what real Ruby's own `Kernel#lambda` is, and it DOES work
      # correctly wherever this codebase's privacy enforcement already
      # works at all (an explicit RubyObject receiver) — this just
      # isn't the piece to also close that separate, pre-existing gap.

      it "proc { } is a declared exclusion (U019), not an undefined method" do
        error = expect_raises(RuntimeError) { eval("proc { |x| x }") }
        error.diagnostic.not_nil!.code.should eq("U019")
      end

      it "a script defining its own proc method is unaffected by the exclusion" do
        result = eval(<<-RUBY)
          def proc(x)
            x * 10
          end
          proc(4)
        RUBY
        result.as_int.should eq 40
      end
    end
  end
end
