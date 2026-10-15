require "../../spec_helper"

module Adjutant
  # Runs `src` and returns its result's `inspect`.
  private def self.leading_dot_outcome(src : String) : String
    eval("result = begin\n#{src}\nend\nresult.inspect").as_string
  end

  describe "a line starting with `.` or `&.`" do
    it "continues the method chain on the line before" do
      src = <<-RUBY
      [1, 2, 3]
        .map { |x| x * 2 }
        .select { |x| x > 2 }
      RUBY
      leading_dot_outcome(src).should eq "[4, 6]"
    end

    it "continues past comment lines, as Ruby 2.7 and later do" do
      src = <<-RUBY
      [1, 2, 3]
        # doubled
        .map { |x| x * 2 }
        # and summed
        .inject(:+)
      RUBY
      leading_dot_outcome(src).should eq "12"
    end

    it "continues with `&.`" do
      leading_dot_outcome("x = nil\nx\n  &.size").should eq "nil"
      leading_dot_outcome(%(x = "ab"\nx\n  &.size)).should eq "2"
    end

    it "continues after a `do` block's `end`" do
      src = <<-RUBY
      [1, 2].map do |x|
        x + 1
      end
        .size
      RUBY
      leading_dot_outcome(src).should eq "2"
    end

    it "continues an assignment's right-hand side" do
      eval("words = %w[b a]\n  .sort\n  .reverse\nwords.inspect").as_string.should eq %(["b", "a"])
    end

    it "reports an error on the line the failing call is on" do
      error = expect_raises(RuntimeError) { eval("[1]\n  .frobnicate") }
      error.diagnostic.try(&.primary.try(&.line)).should eq 2
    end
  end

  describe "a line that only looks like a continuation" do
    it "ends the chain at a blank line, as Ruby does" do
      expect_raises(ParseError) { Parser.new("x = [1, 2]\n\n  .size").parse }
    end

    it "starts a range with `..` rather than continuing" do
      eval("r = 1\n..3\nr").as_int.should eq 1_i64
    end
  end
end
