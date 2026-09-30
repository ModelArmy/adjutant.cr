require "../../spec_helper"

module Adjutant
  # A class `V` holding `n` and comparing by it; with `comparable`, it
  # includes Comparable.
  private def self.comparable_class(comparable : Bool) : String
    <<-RUBY
      class V
        #{comparable ? "include Comparable" : ""}
        attr_reader :n
        def initialize(n)
          @n = n
        end
        def <=>(other)
          other.is_a?(V) ? n <=> other.n : nil
        end
      end
      RUBY
  end

  # Runs `setup`, then returns `expr`'s `inspect`, or the class of the
  # error it raised.
  private def self.comparable_outcome(setup : String, expr : String) : String
    eval(<<-RUBY).as_string
      #{setup}
      begin
        (#{expr}).inspect
      rescue NoMethodError
        "NoMethodError"
      rescue ArgumentError
        "ArgumentError"
      end
      RUBY
  end

  describe "Comparable" do
    with_it = comparable_class(true)
    without_it = comparable_class(false)

    it "derives == and the ordering operators from <=> for a class that includes it" do
      comparable_outcome(with_it, "V.new(1) == V.new(1)").should eq "true"
      comparable_outcome(with_it, "[V.new(1) < V.new(2), V.new(2) <= V.new(2), V.new(3) > V.new(2), V.new(1) >= V.new(2)]")
        .should eq "[true, true, true, false]"
    end

    it "adds between? and clamp" do
      comparable_outcome(with_it, "V.new(2).between?(V.new(1), V.new(3))").should eq "true"
      comparable_outcome(with_it, "V.new(5).clamp(V.new(1), V.new(3)).n").should eq "3"
    end

    it "raises ArgumentError for an ordering when <=> gives nil, and == is false" do
      comparable_outcome(with_it, "V.new(1) < 5").should eq "ArgumentError"
      comparable_outcome(with_it, "V.new(1) == 5").should eq "false"
    end

    it "compares through a module that includes it" do
      setup = "module Ordered\n  include Comparable\nend\n" + comparable_class(false).sub("class V\n", "class V\n  include Ordered\n")
      comparable_outcome(setup, "V.new(1) < V.new(2)").should eq "true"
    end

    it "compares objects inside Arrays" do
      comparable_outcome(with_it, "[V.new(1)] == [V.new(1)]").should eq "true"
    end

    it "is an ancestor of Integer, Float, String and Time, which get between? and clamp" do
      comparable_outcome("", "[5.is_a?(Comparable), 1.5.is_a?(Comparable), \"a\".is_a?(Comparable), Time.now.is_a?(Comparable), [].is_a?(Comparable)]")
        .should eq "[true, true, true, true, false]"
      comparable_outcome("", "[5.between?(1, 10), 5.clamp(1, 3), \"b\".clamp(\"c\", \"d\")]").should eq %([true, 3, "c"])
    end
  end

  describe "a class with <=> that doesn't include Comparable" do
    without_it = comparable_class(false)

    it "has identity ==, as every object does" do
      comparable_outcome(without_it, "V.new(1) == V.new(1)").should eq "false"
      comparable_outcome(without_it + "\nv = V.new(1)", "v == v").should eq "true"
      comparable_outcome(without_it, "[V.new(1)] == [V.new(1)]").should eq "false"
    end

    it "has no ordering operators" do
      comparable_outcome(without_it, "V.new(1) < V.new(2)").should eq "NoMethodError"
    end

    it "still sorts, as sort uses <=> directly" do
      comparable_outcome(without_it, "[V.new(2), V.new(1)].sort.map { |v| v.n }").should eq "[1, 2]"
    end
  end

  describe "Object#<=>" do
    it "is 0 for the same object and nil otherwise" do
      comparable_outcome("o = Object.new", "[o <=> o, o <=> Object.new]").should eq "[0, nil]"
    end
  end
end
