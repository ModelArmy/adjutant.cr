require "../spec_helper"

module Adjutant
  # `expr`'s result as Ruby's `inspect` prints it.
  private def self.splat_value(expr : String) : String
    eval("(#{expr}).inspect").as_string
  end

  # `expr`'s result as Ruby's `inspect` prints it, after a method
  # `collect(*xs)` returning its arguments.
  private def self.splat_collected(expr : String) : String
    eval("def collect(*xs)\n  xs\nend\n(#{expr}).inspect").as_string
  end

  # Whether `expr`, run after `setup`, raises an error a script can
  # rescue as `error_class`.
  private def self.splat_rescued_as?(expr : String, error_class : String, setup : String = "") : Bool
    eval("#{setup}\nbegin\n#{expr}\n:missed\nrescue #{error_class}\n:caught\nend").as_sym.name == "caught"
  end

  # The unresolved-call findings the risk walker reports for `source`.
  private def self.splat_unresolved(source : String) : Array(String)
    interp, _ = make_interp
    tree = RiskWalker.new(interp).walk_body(Parser.new(source).parse)
    RiskAggregator.all_findings(tree)
      .select(&.description.starts_with?("unresolved call: "))
      .map(&.description)
  end

  # An interpreter with flow tracking and two natives returning values
  # labelled High: `t_int` (7) and `t_str` ("a b").
  private def self.splat_labels_interp : Interpreter
    interp = Interpreter.new(
      policy: Policy.new(RiskFlowPolicy.reject_all),
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      effect: TestEffectHandler.new,
      risk_flow_tracking: true,
    )
    label = RiskFlowLabel.of(ProvenanceKind::File, "/secret", Sensitivity::High)
    interp.define_native("t_int") { |_| Value.int(7_i64, label) }
    interp.define_native("t_str") { |_| Value.string("a b", label) }
    interp
  end

  # `source` if its result isn't labelled High, noting the error it
  # raised if it raised one; nil if the result carries the label.
  private def self.splat_unlabelled_result(source : String) : String?
    label = splat_labels_interp.eval(source).label
    source unless label.try(&.sensitivity) == Sensitivity::High
  rescue ex : Exception
    "#{source} (raised #{ex.class}: #{ex.message})"
  end

  # The sources among `sources` whose result isn't labelled High. Empty
  # when every result carries the label.
  private def self.splat_unlabelled(sources : Enumerable(String)) : Array(String)
    sources.compact_map { |source| splat_unlabelled_result(source) }
  end

  describe "a splat (`*x`) as a value" do
    describe "converting its operand, as MRI's vm_splat_array does" do
      it "spreads an Array's elements" do
        splat_value("[0, *[1, 2], 3]").should eq "[0, 1, 2, 3]"
      end

      it "spreads nil as nothing" do
        splat_value("[0, *nil, 1]").should eq "[0, 1]"
      end

      it "spreads a Range through its to_a" do
        splat_value("[*1..3]").should eq "[1, 2, 3]"
      end

      it "spreads a Hash through its to_a" do
        splat_value("[*{a: 1, b: 2}]").should eq "[[:a, 1], [:b, 2]]"
      end

      it "wraps a value without to_a, a String included" do
        splat_value("[*5]").should eq "[5]"
        splat_value(%([*"ab"])).should eq %(["ab"])
        splat_value("[*Object.new].size").should eq "1"
      end

      it "calls a script class's own to_a" do
        src = <<-RUBY
        class Pair
          def to_a
            [1, 2]
          end
        end
        [0, *Pair.new].inspect
        RUBY
        eval(src).as_string.should eq "[0, 1, 2]"
      end

      it "wraps an object whose to_a returns nil" do
        src = <<-RUBY
        class Opaque
          def to_a
            nil
          end
        end
        [*Opaque.new].size
        RUBY
        eval(src).as_int.should eq 1_i64
      end

      it "raises TypeError when to_a returns something other than an Array" do
        setup = <<-RUBY
        class Odd
          def to_a
            5
          end
        end
        RUBY
        splat_rescued_as?("[*Odd.new]", "TypeError", setup).should be_true
      end

      it "copies the Array it spreads" do
        src = <<-RUBY
        source = [1]
        copy = [*source]
        copy.push(2)
        source.inspect
        RUBY
        eval(src).as_string.should eq "[1]"
      end

      it "converts each operand as it is reached, left to right" do
        src = <<-RUBY
        class Logged
          def initialize(log)
            @log = log
          end

          def to_a
            @log.push(:to_a)
            [2]
          end
        end

        def note(log, value)
          log.push(value)
          value
        end

        log = []
        [note(log, 1), *Logged.new(log), note(log, 3)]
        log.inspect
        RUBY
        eval(src).as_string.should eq "[1, :to_a, 3]"
      end
    end

    describe "in a call's arguments" do
      it "passes each element as an argument to a script method" do
        splat_collected("collect(1, *[2, 3], 4)").should eq "[1, 2, 3, 4]"
      end

      it "passes several splats, and none for an empty Array or nil" do
        splat_collected("collect(*[1], *[], *nil, *[2])").should eq "[1, 2]"
      end

      it "fills required and optional parameters" do
        src = <<-RUBY
        def describe_args(a, b, c = 3)
          [a, b, c]
        end
        [describe_args(*[1, 2]), describe_args(*[1, 2, 4])].inspect
        RUBY
        eval(src).as_string.should eq "[[1, 2, 3], [1, 2, 4]]"
      end

      it "gives a rest parameter a new Array" do
        src = <<-RUBY
        def grow(*xs)
          xs.push(9)
        end
        source = [1]
        grow(*source)
        source.inspect
        RUBY
        eval(src).as_string.should eq "[1]"
      end

      it "passes each element to a native method" do
        splat_value("[0].push(*[1, 2])").should eq "[0, 1, 2]"
      end

      it "passes each element to initialize through new" do
        src = <<-RUBY
        class Point
          def initialize(x, y)
            @x = x
            @y = y
          end

          def coords
            [@x, @y]
          end
        end
        Point.new(*[3, 4]).coords.inspect
        RUBY
        eval(src).as_string.should eq "[3, 4]"
      end

      it "comes before keyword arguments" do
        src = <<-RUBY
        def scaled(a, b, by: 1)
          [a * by, b * by]
        end
        scaled(*[1, 2], by: 10).inspect
        RUBY
        eval(src).as_string.should eq "[10, 20]"
      end

      it "never turns a trailing Hash into keyword arguments, as Ruby 3 doesn't" do
        setup = <<-RUBY
        def keyed(a, k: 1)
          [a, k]
        end
        RUBY
        splat_rescued_as?("keyed(*[1, {k: 2}])", "ArgumentError", setup).should be_true
      end

      it "comes before a block literal or a block argument" do
        src = <<-RUBY
        def each_of(*xs)
          xs.map { |x| yield x }
        end
        [each_of(*[1, 2]) { |x| x * 10 }, each_of(*[1, 2], &:to_s)].inspect
        RUBY
        eval(src).as_string.should eq %([[10, 20], ["1", "2"]])
      end

      it "raises ArgumentError when the elements don't match the arity" do
        setup = <<-RUBY
        def pair(a, b)
          [a, b]
        end
        RUBY
        splat_rescued_as?("pair(*[1])", "ArgumentError", setup).should be_true
        splat_rescued_as?("[1, 2].first(*[1, 2])", "ArgumentError").should be_true
      end

      it "passes elements to `yield`, with or without parentheses" do
        src = <<-RUBY
        def twice_with(pair)
          [yield(*pair), (yield *pair)]
        end
        twice_with([1, 2]) { |a, b| a - b }.inspect
        RUBY
        eval(src).as_string.should eq "[-1, -1]"
      end

      it "passes elements to `super`, with or without parentheses" do
        src = <<-RUBY
        class Base
          def diff(a, b)
            a - b
          end
        end

        class Flipped < Base
          def diff(*xs)
            [super(*xs.reverse), (super *xs)]
          end
        end
        Flipped.new.diff(1, 5).inspect
        RUBY
        eval(src).as_string.should eq "[4, -4]"
      end
    end

    describe "after a method name without parentheses" do
      it "is a splat with a space before `*` and none after, as in Ruby" do
        splat_collected("collect *[1, 2]").should eq "[1, 2]"
        splat_collected("collect *3").should eq "[3]"
      end

      it "is a splat after a receiver's method too" do
        src = <<-RUBY
        list = [0]
        list.push *[1, 2]
        list.inspect
        RUBY
        eval(src).as_string.should eq "[0, 1, 2]"
      end

      it "takes further arguments after the splat" do
        splat_collected("collect *[1, 2], 3").should eq "[1, 2, 3]"
      end

      it "is a splat even for a method that takes none, raising as Ruby does" do
        splat_rescued_as?("two *3", "ArgumentError", "def two\n  2\nend").should be_true
      end

      it "multiplies with spaces on both sides or neither" do
        src = <<-RUBY
        def two
          2
        end
        [two * 3, two*3].inspect
        RUBY
        eval(src).as_string.should eq "[6, 6]"
      end

      it "multiplies after a local, as in Ruby" do
        eval("x = 3\ny = 2\nx *y").as_int.should eq 6_i64
      end
    end

    describe "in an Array literal" do
      it "spreads at the start, middle and end" do
        splat_value("[*[1], 2, *[3], 4, *[5]]").should eq "[1, 2, 3, 4, 5]"
      end

      it "makes an empty Array from nothing to spread" do
        splat_value("[*nil, *[]]").should eq "[]"
      end
    end

    describe "as an assignment's value" do
      it "spreads across a multiple assignment's targets" do
        eval("a, b = *[1, 2]\n[a, b].inspect").as_string.should eq "[1, 2]"
      end

      it "spreads through to_a, unlike a value without the splat" do
        eval("a, b = *1..2\n[a, b].inspect").as_string.should eq "[1, 2]"
        eval("a, b = 1..2\n[a, b].inspect").as_string.should eq "[1..2, nil]"
      end

      it "joins splats and plain values" do
        eval("a, b, c = 1, *[2, 3]\n[a, b, c].inspect").as_string.should eq "[1, 2, 3]"
        eval("a, b = *[1], *[2]\n[a, b].inspect").as_string.should eq "[1, 2]"
      end

      it "leaves targets nil for nil" do
        eval("a, b = *nil\n[a, b].inspect").as_string.should eq "[nil, nil]"
      end

      it "makes an Array for a single target" do
        eval("x = *nil\nx.inspect").as_string.should eq "[]"
        eval("x = *5\nx.inspect").as_string.should eq "[5]"
        eval("x = 1, *[2, 3]\nx.inspect").as_string.should eq "[1, 2, 3]"
      end

      it "copies the Array for a single target" do
        eval("source = [1]\ncopy = *source\ncopy.push(2)\nsource.inspect").as_string.should eq "[1]"
      end
    end

    describe "in a `when` list" do
      it "matches any element with ===" do
        src = <<-RUBY
        def kind(n)
          case n
          when *[1, 2] then :small
          when 0, *[3..5] then :middle
          else :other
          end
        end
        [kind(2), kind(4), kind(0), kind(9)].inspect
        RUBY
        eval(src).as_string.should eq "[:small, :middle, :middle, :other]"
      end

      it "matches nothing for nil" do
        eval("found = case 1\nwhen *nil then :hit\nelse :miss\nend\nfound").as_sym.name.should eq "miss"
      end

      it "matches a truthy element in a case without a subject" do
        src = "found = case\nwhen *[nil, false] then :falsy\nwhen *[false, 1] then :truthy\nend\nfound"
        eval(src).as_sym.name.should eq "truthy"
      end
    end

    describe "and risk-flow labels" do
      it "keeps each element's label" do
        splat_unlabelled({
          "[1, *[t_int]].last",
          "[*[t_int], 1].first",
          "[*t_int].first",
          "a, b = *[1, t_int]\nb",
          "x = *t_int\nx.first",
          "def second(a, b)\n  b\nend\nsecond(*[1, t_int])",
        }).should eq [] of String
      end

      it "carries a spread container's label into the Array it builds" do
        splat_unlabelled({
          %([*t_str.split(" ")]),
          %([0, *t_str.split(" ")]),
        }).should eq [] of String
      end
    end

    describe "as the risk walker sees it" do
      it "reports a call in a splat's operand as it would the operand alone" do
        {
          {"f(*fetch_items)", "f(fetch_items)"},
          {"[0, *fetch_items]", "[0, fetch_items]"},
          {"a, b = *fetch_items", "a, b = fetch_items"},
          {"case 1\nwhen *fetch_items then 1\nend", "case 1\nwhen fetch_items then 1\nend"},
        }.each do |splat, plain|
          found = splat_unresolved(splat)
          found.should eq splat_unresolved(plain)
          found.any?(&.includes?("fetch_items")).should be_true
        end
      end
    end
  end
end
