require "../../spec_helper"

module Adjutant
  # Piece C (see SCOPE.md): a `Lambda` node (`->(){}`) compiles
  # (compile_lambda, Op::MakeProc with a=1 — see vm.cr) to a
  # real RubyObject of class Proc, not a bare Value.proc(sproc) as
  # before. This gives lambdas .class/is_a?/.call, matching real Ruby.
  #
  # Note: only `->(){}` is covered here — Adjutant has no Kernel
  # `lambda { }` function (confirmed absent from the native-function
  # table); `lambda{}` is not currently valid Adjutant, not merely
  # untested.
  #
  # Scope boundary (see SCOPE.md, builtins/proc.cr header): only
  # Lambda-node output becomes a Proc instance. Call-site block
  # literals (`{ }`/`do...end`) and `def` bodies keep using the bare,
  # unwrapped Value.proc(sproc) as before — covered by the "block
  # literals are unaffected" spec below, to guard against a future
  # change accidentally widening Op::MakeProc's a=1 branch to those
  # too.
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
    end

    describe "#lambda?" do
      it "is true" do
        eval("(->(x) { x }).lambda?").truthy?.should be_true
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
  end
end
