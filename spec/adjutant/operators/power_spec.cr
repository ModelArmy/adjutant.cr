require "../../spec_helper"

module Adjutant
  # Runs `src` and returns its result's `inspect`, as Ruby would print it.
  private def self.power_outcome(src : String) : String
    eval("(#{src}).inspect").as_string
  end

  # The diagnostic code `src` raises at run time.
  private def self.power_error_code(src : String) : String?
    error = expect_raises(RuntimeError) { eval(src) }
    error.diagnostic.try(&.code)
  end

  # Whether `src` raises an error a script can rescue as `error_class`.
  private def self.power_rescued_as?(src : String, error_class : String) : Bool
    eval("begin\n#{src}\n:missed\nrescue #{error_class}\n:caught\nend").as_sym.name == "caught"
  end

  # An interpreter with flow tracking and a native `tainted(origin)`
  # returning a High-sensitivity Integer 3.
  private def self.power_tainted_interp : Interpreter
    interp = Interpreter.new(
      policy: Policy.new(RiskFlowPolicy.reject_all),
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      effect: TestEffectHandler.new,
      risk_flow_tracking: true,
    )
    interp.define_native("tainted") do |args|
      Value.int(3_i64, RiskFlowLabel.of(ProvenanceKind::File, args.first.as_string, Sensitivity::High))
    end
    interp
  end

  describe "the `**` operator" do
    describe "values" do
      it "raises an Integer to a non-negative Integer power" do
        power_outcome("2 ** 10").should eq "1024"
        power_outcome("(-2) ** 3").should eq "-8"
        power_outcome("7 ** 0").should eq "1"
        power_outcome("0 ** 0").should eq "1"
      end

      it "gives a Float when either side is a Float" do
        power_outcome("2.0 ** 3").should eq "8.0"
        power_outcome("4 ** 0.5").should eq "2.0"
        power_outcome("2 ** 0.5").should eq "1.4142135623730951"
        power_outcome("2.0 ** -2").should eq "0.25"
      end

      it "takes a negative base with a whole exponent, even a Float one" do
        power_outcome("(-8) ** 2.0").should eq "64.0"
        power_outcome("(-2.0) ** 3").should eq "-8.0"
      end
    end

    describe "grammar" do
      it "groups to the right" do
        power_outcome("2 ** 3 ** 2").should eq "512"
      end

      it "binds tighter than `*`" do
        power_outcome("2 * 3 ** 2").should eq "18"
        power_outcome("2 ** 2 * 3").should eq "12"
      end

      it "negates a negative literal's power, as Ruby does" do
        power_outcome("-2 ** 2").should eq "-4"
        power_outcome("-2.0 ** 2").should eq "-4.0"
        power_outcome("(-2) ** 2").should eq "4"
      end

      it "binds tighter than unary minus on any operand" do
        eval("x = 3\n-x ** 2").as_int.should eq(-9_i64)
      end

      it "keeps a negative literal whole before a method call" do
        power_outcome("-2.abs ** 2").should eq "4"
      end

      it "binds looser than `~`" do
        power_outcome("~2 ** 2").should eq "9"
      end

      it "takes a negated exponent" do
        power_outcome("2.0 ** -1").should eq "0.5"
      end

      it "has a compound assignment" do
        eval("x = 3\nx **= 2\nx").as_int.should eq 9_i64
      end
    end

    describe "as a method" do
      it "is called by name" do
        eval("2.**(3)").as_int.should eq 8_i64
        eval("2.0.**(2)").as_float.should eq 4.0
      end

      it "is what `inject(:**)` and `&:**` call" do
        eval("[2, 3, 2].inject(:**)").as_int.should eq 64_i64
        eval("[2, 3, 2].inject(&:**)").as_int.should eq 64_i64
      end
    end

    describe "where Ruby's answer isn't an Integer or a Float" do
      it "raises U026 for a negative Integer exponent, whose Ruby result is a Rational" do
        power_error_code("2 ** -1").should eq "U026"
        power_error_code("1 ** -1").should eq "U026"
      end

      it "raises U026 for a negative base and a fractional exponent, whose Ruby result is a Complex" do
        power_error_code("(-8) ** 0.5").should eq "U026"
        power_error_code("(-8.0) ** (1.0 / 3)").should eq "U026"
      end

      it "lets a script rescue U026 as a RangeError" do
        power_rescued_as?("2 ** -1", "RangeError").should be_true
      end
    end

    describe "errors Ruby raises too" do
      it "raises ZeroDivisionError for zero to a negative Integer power" do
        power_rescued_as?("0 ** -1", "ZeroDivisionError").should be_true
      end

      it "raises U025 for a result past 64 bits" do
        power_error_code("2 ** 64").should eq "U025"
        power_error_code("10 ** 19").should eq "U025"
      end

      it "raises TypeError for an exponent that isn't a number" do
        power_rescued_as?(%(2 ** "x"), "TypeError").should be_true
        power_rescued_as?(%(2.0 ** "x"), "TypeError").should be_true
      end

      it "raises NoMethodError for a receiver without `**`" do
        power_rescued_as?("nil ** 2", "NoMethodError").should be_true
      end
    end

    describe "risk-flow labels" do
      it "carries the base's label to the result" do
        power_tainted_interp.eval(%(tainted("/etc/passwd") ** 2)).label.try(&.sensitivity).should eq Sensitivity::High
      end

      it "carries the exponent's label to the result" do
        power_tainted_interp.eval(%(2 ** tainted("/etc/passwd"))).label.try(&.sensitivity).should eq Sensitivity::High
      end

      it "leaves an unlabelled result unlabelled" do
        power_tainted_interp.eval("2 ** 3").label.should be_nil
      end
    end

    describe "`**` in a parameter list" do
      it "is not read as a parameter name" do
        expect_raises(ParseError) { Parser.new("def f(**)\nend").parse }
      end
    end
  end
end
