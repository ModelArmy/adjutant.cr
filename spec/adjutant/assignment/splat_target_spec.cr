require "../../spec_helper"

module Adjutant
  # The diagnostic code `source` fails to parse with, or nil if it parses.
  private def self.splat_target_parse_code(source : String) : String?
    Parser.new(source).parse
    nil
  rescue ex : ParseError
    ex.diagnostic.try(&.code)
  end

  # An interpreter with flow tracking and a native `t_int` returning 7
  # labelled High.
  private def self.splat_target_labels_interp : Interpreter
    interp = Interpreter.new(
      policy: Policy.new(RiskFlowPolicy.reject_all),
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      effect: TestEffectHandler.new,
      risk_flow_tracking: true,
    )
    label = RiskFlowLabel.of(ProvenanceKind::File, "/secret", Sensitivity::High)
    interp.define_native("t_int") { |_| Value.int(7_i64, label) }
    interp
  end

  describe "a splat target (`*x`) in a multiple assignment, as MRI's expandarray" do
    describe "taking the values the other targets leave" do
      it "after the targets before it" do
        eval("first, *rest = [1, 2, 3]\n[first, rest].inspect").as_string.should eq "[1, [2, 3]]"
      end

      it "before the targets after it" do
        eval("*init, last = [1, 2, 3]\n[init, last].inspect").as_string.should eq "[[1, 2], 3]"
      end

      it "between targets on both sides" do
        eval("a, *b, c = [1, 2, 3, 4]\n[a, b, c].inspect").as_string.should eq "[1, [2, 3], 4]"
      end

      it "as an Array of every value when it stands alone" do
        eval("*all = 1, 2\nall.inspect").as_string.should eq "[1, 2]"
        eval("*all = nil\nall.inspect").as_string.should eq "[nil]"
      end
    end

    describe "with too few values" do
      it "is empty, and the targets before it are padded with nil" do
        eval("a, b, *c = [1]\n[a, b, c].inspect").as_string.should eq "[1, nil, []]"
        eval("a, *b = []\n[a, b].inspect").as_string.should eq "[nil, []]"
      end

      it "is empty, and the targets after it fill from the front" do
        eval("*a, b, c = [1]\n[a, b, c].inspect").as_string.should eq "[[], 1, nil]"
        eval("a, *b, c = [1]\n[a, b, c].inspect").as_string.should eq "[1, [], nil]"
        eval("a, *b, c = [1, 2]\n[a, b, c].inspect").as_string.should eq "[1, [], 2]"
      end
    end

    describe "with the right-hand side" do
      it "takes from several values, splats among them" do
        eval("a, *b = 1, 2, 3\n[a, b].inspect").as_string.should eq "[1, [2, 3]]"
        eval("a, *b = *[1, 2], 3\n[a, b].inspect").as_string.should eq "[1, [2, 3]]"
      end

      it "takes one value that isn't an Array as the only value" do
        eval("a, *b = 5\n[a, b].inspect").as_string.should eq "[5, []]"
      end

      it "takes one value apart through its to_ary" do
        src = <<-RUBY
        class Triple
          def to_ary
            [1, 2, 3]
          end
        end
        a, *b = Triple.new
        [a, b].inspect
        RUBY
        eval(src).as_string.should eq "[1, [2, 3]]"
      end

      it "makes a new Array, leaving the right-hand side unchanged" do
        eval("source = [1, 2]\na, *b = source\nb.push(9)\nsource.inspect").as_string.should eq "[1, 2]"
      end

      it "is the assignment's value" do
        eval("def gathered\n  a, *b = 1, 2\nend\ngathered.inspect").as_string.should eq "[1, 2]"
      end
    end

    describe "as any assignable target" do
      it "an instance variable" do
        src = <<-RUBY
        class Split
          def initialize(items)
            @head, *@tail = items
          end

          def tail
            @tail
          end
        end
        Split.new([1, 2, 3]).tail.inspect
        RUBY
        eval(src).as_string.should eq "[2, 3]"
      end

      it "an index" do
        eval("h = {}\nfirst, *h[:rest] = [1, 2, 3]\nh[:rest].inspect").as_string.should eq "[2, 3]"
      end

      it "an index after the first target, as a plain target too" do
        eval("x = [0, 0]\nb, x[1] = 5, 9\n[b, x].inspect").as_string.should eq "[5, [0, 9]]"
      end
    end

    describe "and risk-flow labels" do
      it "gives the Array the labels of the values it takes" do
        label = splat_target_labels_interp.eval("first, *rest = [1, t_int]\nrest").label
        label.try(&.sensitivity).should eq Sensitivity::High
      end
    end

    describe "where Ruby refuses it" do
      it "rejects a second splat target" do
        splat_target_parse_code("a, *b, *c = [1, 2, 3]").should eq "P002"
      end
    end
  end
end
