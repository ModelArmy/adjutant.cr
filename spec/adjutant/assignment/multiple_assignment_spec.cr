require "../../spec_helper"

module Adjutant
  # Whether `expr`, run after `setup`, raises an error a script can
  # rescue as `error_class`.
  private def self.masgn_rescued_as?(expr : String, error_class : String, setup : String = "") : Bool
    eval("#{setup}\nbegin\n#{expr}\n:missed\nrescue #{error_class}\n:caught\nend").as_sym.name == "caught"
  end

  describe "a multiple assignment" do
    describe "given one value, as MRI's expandarray" do
      it "spreads an Array across the targets" do
        eval("a, b = [1, 2]\n[a, b].inspect").as_string.should eq "[1, 2]"
        eval("pair = [1, 2]\na, b = pair\n[a, b].inspect").as_string.should eq "[1, 2]"
      end

      it "takes a one-element Array literal as that one Array" do
        eval("a, b = [[1, 2]]\n[a, b].inspect").as_string.should eq "[[1, 2], nil]"
        eval("pair = [3, 4]\nfirst, rest = [pair]\n[first, rest].inspect").as_string.should eq "[[3, 4], nil]"
      end

      it "spreads an object through its to_ary" do
        src = <<-RUBY
        class Pair
          def to_ary
            [1, 2]
          end
        end
        a, b = Pair.new
        [a, b].inspect
        RUBY
        eval(src).as_string.should eq "[1, 2]"
      end

      it "takes an object whose to_ary returns nil as one value" do
        src = <<-RUBY
        class Opaque
          def to_ary
            nil
          end
        end
        whole = Opaque.new
        a, b = whole
        [a.equal?(whole), b].inspect
        RUBY
        eval(src).as_string.should eq "[true, nil]"
      end

      it "raises TypeError when to_ary returns something other than an Array" do
        setup = <<-RUBY
        class Odd
          def to_ary
            5
          end
        end
        RUBY
        masgn_rescued_as?("a, b = Odd.new", "TypeError", setup).should be_true
      end

      it "takes a value with to_a but no to_ary as one value" do
        eval("a, b = 1..2\n[a, b].inspect").as_string.should eq "[1..2, nil]"
        eval("a, b = {k: 1}\n[a.class, b].inspect").as_string.should eq "[Hash, nil]"
      end
    end

    describe "given several values" do
      it "gives each target one, an Array included, without spreading it" do
        eval("a, b = [1, 2], 3\n[a, b].inspect").as_string.should eq "[[1, 2], 3]"
      end
    end

    describe "as an expression, as MRI's compile_massign" do
      it "is the Array of several values" do
        eval("def gathered\n  a, b = 1, 2\nend\ngathered.inspect").as_string.should eq "[1, 2]"
      end

      it "is one value itself, whatever it spreads" do
        src = <<-RUBY
        def assign(value)
          a, b = value
        end
        [assign(5), assign([1, 2, 3])].inspect
        RUBY
        eval(src).as_string.should eq "[5, [1, 2, 3]]"
      end

      it "is the same object as one value" do
        src = <<-RUBY
        def assign(value)
          a, b = value
        end
        pair = [1, 2]
        assign(pair).equal?(pair)
        RUBY
        eval(src).as_bool.should be_true
      end

      it "is the Array a splat gathers" do
        eval("def gathered\n  a, b = *[1], 2\nend\ngathered.inspect").as_string.should eq "[1, 2]"
      end
    end
  end
end
