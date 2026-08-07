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
  end
end
