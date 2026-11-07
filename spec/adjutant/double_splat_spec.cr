require "../spec_helper"

module Adjutant
  # Methods for the examples: `opts` returns its two keywords, `mix`
  # its positional, rest and keyword arguments.
  DOUBLE_SPLAT_METHODS = <<-RUBY
  def opts(a: 0, b: 0)
    [a, b]
  end

  def mix(x, *rest, k: 0)
    [x, rest, k]
  end
  RUBY

  # `expr`'s result as `inspect` prints it, after the methods above.
  private def self.double_splat_value(expr : String, setup : String = "") : String
    eval("#{DOUBLE_SPLAT_METHODS}\n#{setup}\n(#{expr}).inspect").as_string
  end

  # Whether `expr`, run after the methods above and `setup`, raises an
  # error a script can rescue as `error_class`.
  private def self.double_splat_rescued_as?(expr : String, error_class : String, setup : String = "") : Bool
    src = "#{DOUBLE_SPLAT_METHODS}\n#{setup}\nbegin\n#{expr}\n:missed\nrescue #{error_class}\n:caught\nend"
    eval(src).as_sym.name == "caught"
  end

  # The unresolved-call findings the risk walker reports for `source`.
  private def self.double_splat_unresolved(source : String) : Array(String)
    interp, _ = make_interp
    tree = RiskWalker.new(interp).walk_body(Parser.new(source).parse)
    RiskAggregator.all_findings(tree)
      .select(&.description.starts_with?("unresolved call: "))
      .map(&.description)
  end

  # An interpreter with flow tracking and a native `t_int` returning 7
  # labelled High.
  private def self.double_splat_labels_interp : Interpreter
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

  # Whether `source`'s result is labelled High.
  private def self.double_splat_labelled?(source : String) : Bool
    double_splat_labels_interp.eval(source).label.try(&.sensitivity) == Sensitivity::High
  end

  TO_HASH_CLASSES = <<-RUBY
  class Opts
    def to_hash
      {a: 7}
    end
  end

  class OddOpts
    def to_hash
      5
    end
  end
  RUBY

  describe "a double splat (`**x`), as Ruby 3.4" do
    describe "in a call's arguments" do
      it "passes a Hash's pairs as keyword arguments" do
        double_splat_value("opts(**{a: 1, b: 2})").should eq "[1, 2]"
      end

      it "joins written keywords and other double splats in order, a later key winning" do
        double_splat_value("opts(a: 1, **{b: 2})").should eq "[1, 2]"
        double_splat_value("opts(**{a: 1, b: 2}, b: 9)").should eq "[1, 9]"
        double_splat_value("opts(a: 1, **{a: 5})").should eq "[5, 0]"
        double_splat_value("opts(**{a: 1}, **{b: 2})").should eq "[1, 2]"
      end

      it "comes after positional arguments and splats" do
        double_splat_value("mix(1, *[2, 3], **{k: 4})").should eq "[1, [2, 3], 4]"
      end

      it "passes no keywords at all for an empty Hash or nil" do
        setup = "def optional(value = :default)\n  value\nend"
        double_splat_value("[optional(**{}), optional(**nil)]", setup).should eq "[:default, :default]"
      end

      it "passes keywords to initialize through new" do
        setup = <<-RUBY
        class Point
          def initialize(x:, y:)
            @x = x
            @y = y
          end

          def coords
            [@x, @y]
          end
        end
        RUBY
        double_splat_value("Point.new(**{x: 1, y: 2}).coords", setup).should eq "[1, 2]"
      end

      it "converts its value through to_hash" do
        double_splat_value("opts(**Opts.new)", TO_HASH_CLASSES).should eq "[7, 0]"
      end

      it "raises TypeError for a value without to_hash" do
        double_splat_rescued_as?("opts(**5)", "TypeError").should be_true
        double_splat_rescued_as?("opts(**[1])", "TypeError").should be_true
      end

      it "raises TypeError when to_hash returns something other than a Hash" do
        double_splat_rescued_as?("opts(**OddOpts.new)", "TypeError", TO_HASH_CLASSES).should be_true
      end

      it "raises ArgumentError for a key the method doesn't take" do
        double_splat_rescued_as?("opts(**{c: 1})", "ArgumentError").should be_true
        double_splat_rescued_as?(%(opts(**{"a" => 1})), "ArgumentError").should be_true
      end

      it "evaluates arguments left to right" do
        setup = <<-RUBY
        def note(log, value)
          log.push(value)
          value
        end
        log = []
        mix(note(log, 1), k: note(log, 2), **note(log, {}))
        RUBY
        double_splat_value("log", setup).should eq "[1, 2, {}]"
      end
    end

    describe "after a method name without parentheses" do
      it "is a double splat with a space before `**` and none after" do
        double_splat_value("opts **{a: 1}").should eq "[1, 0]"
      end

      it "is a double splat after a receiver's method too" do
        setup = <<-RUBY
        class Box
          def opts(a: 0)
            a
          end
        end
        RUBY
        double_splat_value("Box.new.opts **{a: 4}", setup).should eq "4"
      end

      it "raises to the power after a local, or with spaces on both sides" do
        eval("x = 2\ny = 3\nx **y").as_int.should eq 8_i64
        eval("def two\n  2\nend\ntwo ** 3").as_int.should eq 8_i64
      end
    end

    describe "in a Hash literal" do
      it "spreads pairs at any position, a later key winning in the earlier key's place" do
        double_splat_value("{a: 1, **{b: 2}, c: 3}.to_a").should eq "[[:a, 1], [:b, 2], [:c, 3]]"
        double_splat_value("{**{a: 1, b: 2}, a: 9}.to_a").should eq "[[:a, 9], [:b, 2]]"
        double_splat_value("{**{a: 1}, **{a: 2}}.to_a").should eq "[[:a, 2]]"
      end

      it "makes a new Hash, leaving the spread one unchanged" do
        setup = "source = {a: 1}\ncopy = {**source}\ncopy[:b] = 2"
        double_splat_value("source.to_a", setup).should eq "[[:a, 1]]"
      end

      it "converts its value through to_hash" do
        double_splat_value("{**Opts.new}.to_a", TO_HASH_CLASSES).should eq "[[:a, 7]]"
      end

      it "raises TypeError for nil, which only a call's keywords accept" do
        double_splat_rescued_as?("{**nil}", "TypeError").should be_true
      end
    end

    describe "and risk-flow labels" do
      it "keeps each value's label" do
        double_splat_labelled?("{**{a: t_int}}[:a]").should be_true
        double_splat_labelled?("def take(a:)\n  a\nend\ntake(**{a: t_int})").should be_true
      end

      it "carries a spread Hash's label into the Hash it builds" do
        double_splat_labelled?("{b: 1, **{a: t_int}}").should be_true
      end
    end

    describe "as the risk walker sees it" do
      it "reports a call in a double splat's operand as it would the operand alone" do
        {
          {"f(**fetch_opts)", "f(fetch_opts)"},
          {"{b: 1, **fetch_opts}", "{b: 1, a: fetch_opts}"},
        }.each do |spread, plain|
          found = double_splat_unresolved(spread)
          found.should eq double_splat_unresolved(plain)
          found.any?(&.includes?("fetch_opts")).should be_true
        end
      end
    end
  end
end
