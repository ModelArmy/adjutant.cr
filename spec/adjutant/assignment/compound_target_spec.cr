require "../../spec_helper"

module Adjutant
  # A class whose `count` and `name` accessors log each call, and
  # `note`, which logs a value and returns it.
  COMPOUND_TARGET_SETUP = <<-RUBY
  class Tally
    def initialize(count, name)
      @count = count
      @name = name
      @log = []
    end

    def count
      @log.push(:get)
      @count
    end

    def count=(value)
      @log.push(:set)
      @count = value
    end

    def name
      @log.push(:get)
      @name
    end

    def name=(value)
      @log.push(:set)
      @name = value
    end

    def log
      @log
    end

    def raw
      [@count, @name]
    end
  end

  def note(log, value)
    log.push(value)
    value
  end
  RUBY

  # `expr`'s result as `inspect` prints it, after the setup above and
  # `steps`.
  private def self.compound_value(steps : String, expr : String) : String
    eval("#{COMPOUND_TARGET_SETUP}\n#{steps}\n(#{expr}).inspect").as_string
  end

  # The unresolved-call findings the risk walker reports for `source`.
  private def self.compound_unresolved(source : String) : Array(String)
    interp, _ = make_interp
    tree = RiskWalker.new(interp).walk_body(Parser.new(source).parse)
    RiskAggregator.all_findings(tree)
      .select(&.description.starts_with?("unresolved call: "))
      .map(&.description)
  end

  describe "a compound assignment" do
    describe "through an attribute" do
      it "reads with the getter and writes with the setter, once each" do
        steps = "t = Tally.new(1, nil)\nresult = t.count += 5"
        compound_value(steps, "[result, t.raw, t.log]").should eq "[6, [6, nil], [:get, :set]]"
      end

      it "takes every operator" do
        steps = "t = Tally.new(10, nil)\nt.count -= 3\nt.count *= 2\nt.count **= 2"
        compound_value(steps, "t.raw").should eq "[196, nil]"
      end

      it "evaluates the receiver once" do
        steps = "t = Tally.new(1, nil)\nseen = []\nnote(seen, t).count += 1"
        compound_value(steps, "[seen.size, t.raw]").should eq "[1, [2, nil]]"
      end

      it "works through self inside a method" do
        steps = <<-RUBY
        class Bumper
          def initialize
            @hits = 0
          end

          def hits
            @hits
          end

          def hits=(value)
            @hits = value
          end

          def bump
            self.hits += 1
          end
        end
        b = Bumper.new
        b.bump
        RUBY
        compound_value(steps, "[b.bump, b.hits]").should eq "[2, 2]"
      end

      describe "with ||=" do
        it "assigns when the getter's value is falsy, and is the new value" do
          steps = "t = Tally.new(0, nil)\nresult = t.name ||= \"x\""
          compound_value(steps, "[result, t.raw, t.log]").should eq %(["x", [0, "x"], [:get, :set]])
        end

        it "doesn't call the setter or evaluate the value when truthy, and is the old value" do
          steps = "t = Tally.new(0, \"kept\")\nlog = []\nresult = t.name ||= note(log, \"x\")"
          compound_value(steps, "[result, t.log, log]").should eq %(["kept", [:get], []])
        end
      end

      describe "with &&=" do
        it "assigns when the getter's value is truthy" do
          steps = "t = Tally.new(0, \"old\")\nresult = t.name &&= \"new\""
          compound_value(steps, "[result, t.raw, t.log]").should eq %(["new", [0, "new"], [:get, :set]])
        end

        it "doesn't call the setter when falsy, and is the old value" do
          steps = "t = Tally.new(0, nil)\nresult = t.name &&= \"new\""
          compound_value(steps, "[result, t.log]").should eq "[nil, [:get]]"
        end
      end
    end

    describe "through an index" do
      it "evaluates the receiver and the index once" do
        steps = "log = []\nh = {a: 1}\nnote(log, h)[note(log, :a)] += 1"
        compound_value(steps, "[h[:a], log.size]").should eq "[2, 2]"
      end

      it "evaluates them once for ||= too, whether it assigns or not" do
        steps = "log = []\nh = {a: 1}\nh[note(log, :a)] ||= 5\nh[note(log, :b)] ||= 6"
        compound_value(steps, "[h.to_a, log]").should eq "[[[:a, 1], [:b, 6]], [:a, :b]]"
      end

      it "evaluates a length once" do
        steps = "log = []\na = [1, 2, 3]\na[0, note(log, 2)] += [9]"
        compound_value(steps, "[a, log]").should eq "[[1, 2, 9, 3], [2]]"
      end
    end

    describe "as the risk walker sees it" do
      it "reports a call in an attribute target's receiver as a read of the attribute would" do
        found = compound_unresolved("fetch_tally.count += 1")
        found.should eq compound_unresolved("fetch_tally.count")
        found.any?(&.includes?("fetch_tally")).should be_true
      end
    end
  end
end
