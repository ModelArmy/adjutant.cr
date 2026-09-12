require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "arithmetic" do
      it "adds integers" do
        eval("1 + 2").as_int.should eq 3_i64
      end

      it "subtracts integers" do
        eval("5 - 3").as_int.should eq 2_i64
      end

      it "multiplies integers" do
        eval("3 * 4").as_int.should eq 12_i64
      end

      it "divides integers (floor)" do
        eval("7 / 2").as_int.should eq 3_i64
      end

      it "computes modulo" do
        eval("7 % 3").as_int.should eq 1_i64
      end

      it "adds floats" do
        eval("1.5 + 2.5").as_float.should be_close(4.0, 1e-10)
      end

      it "promotes int+float to float" do
        eval("1 + 2.5").as_float.should be_close(3.5, 1e-10)
      end

      it "concatenates strings with +" do
        eval(%("hello" + " world")).as_string.should eq "hello world"
      end

      it "evaluates a negative integer literal" do
        # Name updated 2026-07-25 — `-7` no longer literally negates
        # anything at runtime (it's a fused negative IntLiteral, see
        # literals/compiler_spec.cr's "fused literal, not Unary+Neg"
        # spec); this assertion itself is unaffected either way.
        eval("-7").as_int.should eq -7_i64
      end

      # End-to-end regression for the exact bug the person found
      # (2026-07-25, via mruby's spec/scripts/mruby/float.rb fixture):
      # `-0.0.to_s` used to raise R005 for negating a String — .to_s
      # ran FIRST (on positive 0.0), THEN negation was attempted on
      # the resulting String. Now correctly groups as `(-0.0).to_s`.
      it "groups unary minus with an adjacent numeric literal before postfix, not after" do
        eval("-0.0.to_s").as_string.should eq "-0.0"
      end

      it "still attempts to negate a call's RESULT when the minus target is not a literal (raises for a non-numeric result, matching Op::Neg's existing behavior)" do
        # `n` is a variable, not a literal, so this remains
        # Unary(Minus, Call(...)) — negating n.to_s's RESULT, not
        # fusing with anything. Adjutant's Op::Neg only accepts
        # Integer/Float (see R005's raise site in vm.cr) — there's no
        # per-type -@ dispatch the way modern Ruby
        # has (Ruby's own String#-@ would actually make -(a.to_s) NOT
        # raise, just return a frozen copy — Adjutant deliberately
        # doesn't replicate that nuance, matching Op::Neg's existing,
        # narrower numeric-only contract, unchanged by this fix).
        expect_raises(RuntimeError, /cannot be applied/) { eval("n = 0.0\n-n.to_s") }
      end

      # End-to-end regression for the exact values the person reported
      # (2026-07-25, via mruby's float.rb "Float literal underflow"
      # test) — String#to_f64 raised ArgumentError on all three
      # (confirmed via the person's own error output:
      # `Invalid Float64: "-92170141183460469231731687303715884105729e-383"`).
      # See literals/compiler_spec.cr's "underflow/overflow" describe
      # block for narrower, more exhaustive coverage of the fix itself
      # (including two edge cases found while implementing it: an
      # all-zero mantissa with a huge exponent, and a near-boundary
      # literal the approximate safety margin alone doesn't catch).
      it "evaluates the person's exact reported underflow/overflow literals without raising" do
        eval("1.0e-400").as_float.should eq 0.0
        eval("9.99e-344").as_float.should eq 0.0
        f = eval("-92170141183460469231731687303715884105729e-383").as_float
        f.should eq 0.0
        (1.0 / f).should be < 0
      end

      # End-to-end regression for the exact bug the person found
      # (2026-07-25): a bare (no-paren) call whose first argument is a
      # negative literal used to raise a parse error — see
      # methods_and_calls/parser_spec.cr's "parses a bare call whose
      # first argument is a negative literal" for the narrower
      # parser-level coverage and the full root-cause trace (including
      # the known_local?-based first attempt that was caught and
      # discarded before shipping).
      it "calls a bare (no-paren) method whose arguments are negative literals" do
        result = eval(<<-RUBY)
          def eq(a, b)
            a == b
          end
          eq -1, -1
        RUBY
        result.truthy?.should be_true
      end

      it "still evaluates subtraction as a binary operator regardless of local status" do
        eval("a = 10\nb = 3\na - b").as_int.should eq 7_i64
        eval("n = 5\nn - 1").as_int.should eq 4_i64
      end

      # Fixed 2026-07-25 (SCOPE.md's "Unary + is entirely unsupported"
      # entry). Unlike unary minus, unary + is a genuine numeric no-op
      # in real Ruby (confirmed via Ruby's own precedence doc and
      # Ruby core discussion of the operator) — Op::Pos pushes the
      # SAME value back unchanged rather than reconstructing it,
      # specifically so it doesn't reproduce Op::Neg's separate,
      # pre-existing label-dropping behavior (Value.int(-v.as_int) with
      # no label arg defaults to label: nil — out of scope to fix here,
      # noted for the record, not touched by this spec).
      it "applies unary plus to an integer as a no-op" do
        eval("+7").as_int.should eq 7_i64
      end

      it "applies unary plus to a float as a no-op" do
        eval("+7.5").as_float.should be_close(7.5, 1e-10)
      end

      it "applies unary plus to a variable, not just a literal" do
        # The person's own reported repro shape — `+n` where `n` is a
        # local, not `+1` a bare literal. Unlike unary minus, unary +
        # needs NO literal-fusion special case at all (there's no
        # "positive literal" AST node in Ruby), so this should already
        # work identically to the bare-literal case above once
        # parse_unary has a TokenKind::Plus branch at all.
        eval("n = 1\n+n").as_int.should eq 1_i64
      end

      it "raises applying unary plus to a non-numeric value" do
        expect_raises(RuntimeError, /`\+` cannot be applied/) { eval(%(+"str")) }
      end

      it "raises on divide by zero" do
        expect_raises(RuntimeError) { eval("1 / 0") }
      end
    end

    describe "comparison" do
      it "compares integers with ==" do
        eval("1 == 1").as_bool.should be_true
        eval("1 == 2").as_bool.should be_false
      end

      it "compares integers with !=" do
        eval("1 != 2").as_bool.should be_true
      end

      it "compares integers with <" do
        eval("1 < 2").as_bool.should be_true
        eval("2 < 1").as_bool.should be_false
      end

      it "compares integers with <=" do
        eval("2 <= 2").as_bool.should be_true
      end

      it "compares integers with >" do
        eval("3 > 2").as_bool.should be_true
      end

      it "compares nil == nil" do
        eval("nil == nil").as_bool.should be_true
      end

      it "compares symbols by identity" do
        eval(":foo == :foo").as_bool.should be_true
        eval(":foo == :bar").as_bool.should be_false
      end
    end

    describe "a === b (bare infix, added 2026-08-21)" do
      # `===` joined `==` as a fixed VM opcode (Op::TripleEq, vm.cr's
      # triple_eq_matches?) rather than gaining ordinary receiver
      # dispatch — see DEVELOPMENT.md's own entry for the full
      # reasoning. Shares its implementation (not just its behavior)
      # with case/when's per-`when`-pattern check — see
      # control_flow/vm_spec.cr's "case/when" describe block for that
      # side, which exercises the exact same hardcoded branches.

      it "matches by type with a Class pattern" do
        eval("Integer === 5").as_bool.should be_true
        eval("Integer === \"x\"").as_bool.should be_false
      end

      it "matches by membership with a Range pattern" do
        eval("(1..10) === 5").as_bool.should be_true
        eval("(1..10) === 20").as_bool.should be_false
      end

      it "matches by membership with a beginless/endless Range pattern (fixed 2026-08-22)" do
        # SCOPE.md's now-resolved Must Fix entry: range_include?
        # (vm.cr) had no nil-bound handling, so a beginless/endless
        # range's === silently answered false for a genuinely included
        # value — the missing bound (a real Value.nil_value) fell
        # through ValueOps.compare's type-pair case to its own
        # else -> false, short-circuiting range_include? immediately.
        eval("(..10) === 5").as_bool.should be_true
        eval("(..10) === 20").as_bool.should be_false
        eval("(1..) === 20").as_bool.should be_true
        eval("(1..) === 0").as_bool.should be_false
      end

      it "matches a Regexp pattern against a String" do
        eval(%(/^h/ === "hello")).as_bool.should be_true
        eval(%(/^z/ === "hello")).as_bool.should be_false
      end

      it "matches by calling a Proc/lambda pattern and checking truthiness" do
        eval("->(x) { x.even? } === 4").as_bool.should be_true
        eval("->(x) { x.even? } === 5").as_bool.should be_false
      end

      it "falls back to == for an ordinary value pattern" do
        eval("5 === 5").as_bool.should be_true
        eval("5 === 6").as_bool.should be_false
      end

      it "gives === the same precedence tier as ==, not <=>'s" do
        # a === b + c should parse (and therefore evaluate) as
        # a === (b + c), same as a == b + c would — confirmed at the
        # parser level too (operators/parser_spec.cr), this is the
        # end-to-end version.
        eval("7 === 3 + 4").as_bool.should be_true
      end

      it "dot-call raises undefined-method, same as a.==(b) always has" do
        error = expect_raises(RuntimeError) { eval("Integer.===(5)") }
        error.diagnostic.not_nil!.code.should eq("R008")
      end
    end

    describe "<=> and comparisons on script objects" do
      # SCOPE.md's `<=>` item: real Ruby's own answer to "how do
      # </<=/>/>= work for a custom object" is the Comparable mixin,
      # deriving all four from one `<=>` — Adjutant has no mixins, so
      # `<`/`<=`/`>`/`>=` dispatch through a script-defined `<=>`
      # directly for RubyObject operands, as a fixed VM rule standing
      # in for it.
      it "dispatches < through a script-defined <=>" do
        src = <<-RUBY
        class Box
          def initialize(v); @v = v; end
          def v; @v; end
          def <=>(other); @v <=> other.v; end
        end
        Box.new(1) < Box.new(2)
        RUBY
        eval(src).as_bool.should be_true
      end

      it "dispatches <=, >, >= through the same <=>" do
        src = <<-RUBY
        class Box
          def initialize(v); @v = v; end
          def v; @v; end
          def <=>(other); @v <=> other.v; end
        end
        [Box.new(2) <= Box.new(2), Box.new(3) > Box.new(2), Box.new(2) >= Box.new(2)]
        RUBY
        result = eval(src).as_array
        result[0].as_bool.should be_true
        result[1].as_bool.should be_true
        result[2].as_bool.should be_true
      end

      it "dispatches <=> itself as a real receiver call, not implicit self" do
        # Regression check for compile_spaceship's missing receiver
        # bit (found while implementing this item) — before the fix,
        # `a <=> b` never actually called `<=>` ON `a` at all, so this
        # would have failed to resolve rather than returning 0.
        src = <<-RUBY
        class Box
          def initialize(v); @v = v; end
          def <=>(other); @v <=> other; end
        end
        b = Box.new(5)
        b <=> 5
        RUBY
        eval(src).as_int.should eq(0_i64)
      end

      it "leaves ordinary Integer/Float/String comparisons untouched" do
        # Regression check: the RubyObject branch must not be taken
        # for base types — these still go straight through ValueOps,
        # same as before this item.
        eval("1 < 2").as_bool.should be_true
        eval("1.5 <= 1.5").as_bool.should be_true
        eval("\"a\" < \"b\"").as_bool.should be_true
      end

      it "raises like an ordinary undefined method when <=> isn't defined" do
        # No "is <=> defined?" pre-check, per SCOPE.md's decision — an
        # absent <=> fails the same way any other undefined method
        # call already does. This also confirms exec_builtin's own new
        # "<=>" fallback (added below, for base types) correctly stays
        # out of a RubyObject's way rather than silently returning nil
        # in its place, AND is call_method's own regression case for
        # the "nothing resolves, must raise cleanly through an
        # isolated frame stack" path — found failing with a raw
        # Crystal IndexError (current_frame crashing on a genuinely
        # empty @frames) before call_method grew its sentinel frame.
        error = expect_raises(RuntimeError) do
          eval("class Bare; end\nBare.new < Bare.new")
        end
        error.diagnostic.not_nil!.code.should eq("R008")
      end

      it "raises R013 when <=> returns something other than an Integer" do
        # Confirmed against real Ruby (irb, with Comparable included):
        # ArgumentError: comparison of Foo with Foo failed.
        src = <<-RUBY
        class Foo
          def <=>(other); nil; end
        end
        Foo.new < Foo.new
        RUBY
        error = expect_raises(RuntimeError) do
          eval(src)
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("R013")
        diag.data["left"].should eq("Foo")
        diag.data["right"].should eq("Foo")
      end
    end

    describe "== derived from a script-defined <=> (Comparable-style, no mixin needed)" do
      # Companion to the "<=> and comparisons on script objects" block
      # above — `<`/`<=`/`>`/`>=` already dispatched through a
      # script-defined `<=>` before this; `==` (Op::Eq, a separate
      # opcode from compare/compare_via_spaceship) did not, and fell
      # back to plain reference identity for ANY two RubyObjects
      # regardless of whether they defined `<=>` — a real, documented
      # gap (see the removed comment in value_ops.cr's
      # ValueOps.equal?) surfaced while designing a real `Time` type
      # that needed value equality. See values_equal?/
      # robject_equal_via_spaceship? (vm.cr) for the fix and the full
      # reasoning on why `==` swallows a bad `<=>` into `false` where
      # `<`/`<=`/`>`/`>=` deliberately raise R013 instead — that
      # asymmetry is real Ruby Comparable behavior, not new here.

      it "two different objects with the same <=>-comparable value are == (NOT identity)" do
        eval(<<-RUBY).as_bool.should eq true
        class Box
          def initialize(v); @v = v; end
          def <=>(other); @v <=> other.v; end
          def v; @v; end
        end
        Box.new(5) == Box.new(5)
        RUBY
      end

      it "two objects with different <=>-comparable values are not ==" do
        eval(<<-RUBY).as_bool.should eq false
        class Box
          def initialize(v); @v = v; end
          def <=>(other); @v <=> other.v; end
          def v; @v; end
        end
        Box.new(5) == Box.new(6)
        RUBY
      end

      it "falls back to plain identity when no <=> is defined at all — unchanged from before this fix" do
        eval(<<-RUBY).as_bool.should eq false
        class Bare; end
        Bare.new == Bare.new
        RUBY
      end

      it "identity still holds for the SAME object with no <=> defined" do
        eval(<<-RUBY).as_bool.should eq true
        class Bare; end
        a = Bare.new
        a == a
        RUBY
      end

      it "<=> returning nil (genuinely unorderable) makes == false, NOT a raised R013 — unlike < which does raise" do
        eval(<<-RUBY).as_bool.should eq false
        class Foo
          def <=>(other); nil; end
        end
        Foo.new == Foo.new
        RUBY
      end

      it "<=> raising makes == false rather than propagating the error — matches real Ruby's non-raising Comparable#==" do
        eval(<<-RUBY).as_bool.should eq false
        class Foo
          def <=>(other); raise "boom"; end
        end
        Foo.new == Foo.new
        RUBY
      end

      it "does not affect Array/Hash/Range's own established content-equality special cases" do
        eval("[1, 2, 3] == [1, 2, 3]").as_bool.should eq true
        eval("(1..5) == (1..5)").as_bool.should eq true
      end
    end

    describe "VM#call_method against a script-defined method (regression)" do
      # Found 2026-08-06 while testing the <=> item above, but not
      # specific to <=> at all — a real, general bug in call_method
      # itself: dispatch_call's script-method branch only pushes a
      # frame and returns a sentinel (Value.nil_value), trusting the
      # caller to be the main execute loop, which naturally continues
      # on to run it. call_method's one prior real caller (Range#each,
      # via #succ — see builtins/range.cr) only ever targeted NATIVE
      # methods (Integer#succ), so this never got exercised until a
      # script-defined <=> became the first script-method caller.
      # Range#each's own #succ dispatch is call_method's OTHER real
      # caller and a completely independent way to prove the general
      # fix, decoupled from <=> entirely.
      it "lets Range#each advance via a script-defined #succ, not just Integer's native one" do
        src = <<-RUBY
        class Ticker
          def initialize(n); @n = n; end
          def n; @n; end
          def succ; Ticker.new(@n + 1); end
          def <=>(other); @n <=> other.n; end
        end
        total = 0
        (Ticker.new(1)..Ticker.new(3)).each { |t| total += t.n }
        total
        RUBY
        eval(src).as_int.should eq(6_i64)
      end
    end

    describe "<=> on base types (Integer/Float/String)" do
      # Found while testing the item above: the literal `<=>`
      # operator had no implementation at all for base types before
      # this — not a separate feature, a hard dependency of the one
      # above, since a script's own `<=>` almost always delegates to
      # a numeric `<=>` internally (real Ruby's own idiomatic
      # Comparable pattern). See ValueOps.spaceship and
      # exec_builtin's "<=>" case.
      it "returns -1, 0, 1 for Integer <=> Integer" do
        eval("1 <=> 2").as_int.should eq(-1_i64)
        eval("2 <=> 2").as_int.should eq(0_i64)
        eval("3 <=> 2").as_int.should eq(1_i64)
      end

      it "returns a sign for Float <=> Float, and mixed Integer/Float" do
        eval("1.5 <=> 2.5").as_int.should eq(-1_i64)
        eval("1 <=> 1.5").as_int.should eq(-1_i64)
      end

      it "returns a sign for String <=> String" do
        eval("\"a\" <=> \"b\"").as_int.should eq(-1_i64)
        eval("\"b\" <=> \"a\"").as_int.should eq(1_i64)
      end

      it "returns nil for genuinely incomparable operands" do
        # Matches real Ruby: 5 <=> "a" is nil, not an error and not 0
        # — distinguishing "incomparable" from "equal" is exactly why
        # ValueOps.spaceship isn't just derived from compare(:<)/(:>).
        eval("(1 <=> \"a\").nil?").as_bool.should be_true
      end
    end

    describe "boolean logic" do
      it "short-circuits ||" do
        eval("true || false").as_bool.should be_true
        eval("false || true").as_bool.should be_true
      end

      it "short-circuits &&" do
        eval("true && false").as_bool.should be_false
        eval("true && true").as_bool.should be_true
      end

      it "negates with !" do
        eval("!true").as_bool.should be_false
        eval("!false").as_bool.should be_true
        eval("!nil").as_bool.should be_true
      end
    end

    describe "arithmetic errors raise the correct Ruby error class, not a generic RuntimeError" do
      # ValueOps' add/op/div/mod/int_op now classify their own
      # failures (TypeError for bad operand types, ZeroDivisionError
      # for division/modulo by zero) instead of everything collapsing
      # into a plain RuntimeError regardless of what actually went
      # wrong — a real, previously-unnoticed gap: `0 + nil` raised
      # RuntimeError, and ZeroDivisionError existed in the exception
      # hierarchy but was never actually reachable from arithmetic.
      it "adding incompatible types raises TypeError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("1 + nil") }
        error.error_value.not_nil!.as_robject.rclass.name.should eq("TypeError")
      end

      it "subtracting/multiplying incompatible types raises TypeError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("1 - nil") }
        error.error_value.not_nil!.as_robject.rclass.name.should eq("TypeError")
      end

      it "dividing incompatible types raises TypeError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("1 / nil") }
        error.error_value.not_nil!.as_robject.rclass.name.should eq("TypeError")
      end

      it "modulo with incompatible types raises TypeError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("1 % nil") }
        error.error_value.not_nil!.as_robject.rclass.name.should eq("TypeError")
      end

      it "bitwise ops on a non-Integer raise TypeError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("1 & nil") }
        error.error_value.not_nil!.as_robject.rclass.name.should eq("TypeError")
      end

      it "integer division by zero raises ZeroDivisionError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("1 / 0") }
        error.error_value.not_nil!.as_robject.rclass.name.should eq("ZeroDivisionError")
      end

      it "integer modulo by zero raises ZeroDivisionError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("1 % 0") }
        error.error_value.not_nil!.as_robject.rclass.name.should eq("ZeroDivisionError")
      end

      it "TypeError is rescuable from script" do
        eval(<<-RUBY).as_bool.should be_true
          begin
            1 + nil
            false
          rescue TypeError
            true
          end
        RUBY
      end

      it "ZeroDivisionError is rescuable from script" do
        eval(<<-RUBY).as_bool.should be_true
          begin
            1 / 0
            false
          rescue ZeroDivisionError
            true
          end
        RUBY
      end
    end
  end
end
