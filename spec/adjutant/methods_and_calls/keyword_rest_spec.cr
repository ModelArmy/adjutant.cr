require "../../spec_helper"

module Adjutant
  # The diagnostic code `source` fails to parse with, or nil if it parses.
  private def self.keyword_rest_parse_code(source : String) : String?
    Parser.new(source).parse
    nil
  rescue ex : ParseError
    ex.diagnostic.try(&.code)
  end

  # An interpreter with flow tracking and a native `t_int` returning 7
  # labelled High.
  private def self.keyword_rest_labels_interp : Interpreter
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

  KEYWORD_REST_METHOD = <<-RUBY
  def rest_of(a: 0, **rest)
    [a, rest.to_a]
  end
  RUBY

  describe "a keyword-rest parameter (`**opts`), as Ruby 3.4" do
    describe "collecting keywords" do
      it "takes the keywords no other parameter takes, as a Hash with Symbol keys" do
        eval(KEYWORD_REST_METHOD + "\nrest_of(a: 1, b: 2, c: 3).inspect").as_string.should eq "[1, [[:b, 2], [:c, 3]]]"
      end

      it "keeps them in the order passed" do
        eval(KEYWORD_REST_METHOD + "\nrest_of(c: 3, b: 2).inspect").as_string.should eq "[0, [[:c, 3], [:b, 2]]]"
      end

      it "is an empty Hash without them" do
        eval(KEYWORD_REST_METHOD + "\nrest_of.inspect").as_string.should eq "[0, []]"
        eval("def opts_class(**opts)\n  opts.class\nend\nopts_class.inspect").as_string.should eq "Hash"
      end

      it "takes them from a double splat" do
        eval(KEYWORD_REST_METHOD + "\nrest_of(**{a: 1, b: 2}).inspect").as_string.should eq "[1, [[:b, 2]]]"
      end

      it "lets a method take any keyword" do
        eval("def any(**opts)\n  opts.to_a\nend\nany(x: 1).inspect").as_string.should eq "[[:x, 1]]"
      end

      it "sits after positional parameters, a splat and keywords" do
        src = <<-RUBY
        def mix(a, *rest, k: 0, **opts)
          [a, rest, k, opts.to_a]
        end
        mix(1, 2, k: 3, z: 4).inspect
        RUBY
        eval(src).as_string.should eq "[1, [2], 3, [[:z, 4]]]"
      end

      it "is a new Hash each call" do
        src = <<-RUBY
        def keep(**opts)
          opts
        end
        first = keep(a: 1)
        first[:b] = 2
        keep(a: 1).to_a.inspect
        RUBY
        eval(src).as_string.should eq "[[:a, 1]]"
      end
    end

    describe "forwarding" do
      it "passes everything on with a splat and a double splat" do
        src = <<-RUBY
        def inner(a, b: 0)
          [a, b]
        end

        def outer(*args, **opts)
          inner(*args, **opts)
        end
        [outer(1, b: 2), outer(1)].inspect
        RUBY
        eval(src).as_string.should eq "[[1, 2], [1, 0]]"
      end

      it "passes them on through a bare `super`" do
        src = <<-RUBY
        class Base
          def pick(a: 0, z: 0)
            [a, z]
          end
        end

        class Kid < Base
          def pick(a: 0, **rest)
            super
          end
        end
        Kid.new.pick(a: 1, z: 2).inspect
        RUBY
        eval(src).as_string.should eq "[1, 2]"
      end
    end

    describe "in a block" do
      it "is empty, and an Array isn't split for one positional parameter" do
        eval("[[1, 2]].map { |pair, **opts| [pair, opts.to_a] }.inspect").as_string.should eq "[[[1, 2], []]]"
      end
    end

    describe "and risk-flow labels" do
      it "keeps each keyword's label, and gives the Hash their labels" do
        source = "def take(**opts)\n  opts\nend\n"
        {source + "take(a: t_int)[:a]", source + "take(a: t_int, b: 1)"}.each do |src|
          keyword_rest_labels_interp.eval(src).label.try(&.sensitivity).should eq Sensitivity::High
        end
      end
    end

    describe "where Ruby refuses it" do
      it "rejects a second keyword rest, or a parameter after it other than a block" do
        keyword_rest_parse_code("def f(**a, **b)\nend").should eq "P006"
        keyword_rest_parse_code("def f(**opts, k: 1)\nend").should eq "P006"
        keyword_rest_parse_code("def f(**opts, *rest)\nend").should eq "P006"
      end
    end
  end
end
