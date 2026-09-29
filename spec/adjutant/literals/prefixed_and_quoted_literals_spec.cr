require "../../spec_helper"

module Adjutant
  describe "Integer literal prefixes" do
    it "reads a leading zero as octal" do
      eval("0644").as_int.should eq 420
      eval("0_7").as_int.should eq 7
      eval("-010").as_int.should eq(-8)
      eval("0").as_int.should eq 0
    end

    it "reads 0o, 0x, 0b and 0d, in either case" do
      eval("0o17").as_int.should eq 15
      eval("0O17").as_int.should eq 15
      eval("0x1F").as_int.should eq 31
      eval("0b101").as_int.should eq 5
      eval("0B11").as_int.should eq 3
      eval("0d19").as_int.should eq 19
    end

    it "rejects a digit outside the base" do
      {"08", "0b102", "0o9"}.each do |src|
        expect_raises(ParseError) { Parser.new(src, "t.rb").parse }
      end
    end

    it "leaves a Float with a leading zero alone" do
      eval("0.5").as_float.should eq 0.5
    end
  end

  describe "quoted Symbol literals" do
    it "decodes escapes in a double-quoted Symbol, not a single-quoted one" do
      eval(%(:"a\\nb".to_s.size)).as_int.should eq 3
      eval(%(:'a\\nb'.to_s.size)).as_int.should eq 4
    end

    it "interpolates a double-quoted Symbol" do
      eval(%(:"x\#{1 + 1}".inspect)).as_string.should eq ":x2"
    end
  end

  describe "heredocs" do
    it "reads two openers on one line, bodies in order" do
      eval(<<-'RUBY').as_string.should eq "x\ny2\n"
        def two(a, b)
          a + b
        end
        r = two(<<~A, <<~B)
          x
        A
          y#{1 + 1}
        B
        r
        RUBY
    end
  end
end
