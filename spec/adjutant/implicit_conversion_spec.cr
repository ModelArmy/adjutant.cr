require "../spec_helper"

module Adjutant
  # A class, `Pair`, whose public `to_ary` is `[1, 2]`.
  private def self.conversion_pair : String
    <<-RUBY
      class Pair
        def to_ary
          [1, 2]
        end
      end
      RUBY
  end

  describe "implicit conversions, as MRI's rb_check_funcall makes them" do
    describe "through a private (top-level) method" do
      it "spreads a value through a top-level to_a" do
        src = <<-RUBY
          def to_a
            [:converted]
          end
          [0, *5].inspect
          RUBY
        eval(src).as_string.should eq "[0, :converted]"
      end

      it "takes a value apart through a top-level to_ary" do
        src = <<-RUBY
          def to_ary
            [1, 2]
          end
          first, second = 5
          [first, second].inspect
          RUBY
        eval(src).as_string.should eq "[1, 2]"
      end

      it "double-splats a value through a top-level to_hash" do
        src = <<-RUBY
          def to_hash
            {port: 8080}
          end

          def connect(port: 1)
            port
          end
          connect(**5).inspect
          RUBY
        eval(src).as_string.should eq "8080"
      end

      it "still prefers a value's own to_a" do
        src = <<-RUBY
          def to_a
            [:converted]
          end
          [*1..2].inspect
          RUBY
        eval(src).as_string.should eq "[1, 2]"
      end
    end

    describe "of a block's lone argument, through to_ary" do
      it "spreads it across a block's parameters" do
        src = <<-RUBY
          #{conversion_pair}
          [Pair.new].map { |first, second| [first, second] }.inspect
          RUBY
        eval(src).as_string.should eq "[[1, 2]]"
      end

      it "spreads it across a for loop's targets" do
        src = <<-RUBY
          #{conversion_pair}
          got = []
          for first, second in [Pair.new]
            got.push(first, second)
          end
          got.inspect
          RUBY
        eval(src).as_string.should eq "[1, 2]"
      end

      it "raises TypeError when to_ary returns something other than an Array" do
        src = <<-RUBY
          class Odd
            def to_ary
              5
            end
          end

          begin
            [Odd.new].map { |first, second| first }
          rescue TypeError => e
            e.class.inspect
          end
          RUBY
        eval(src).as_string.should eq "TypeError"
      end

      it "leaves it whole for a block with one parameter" do
        src = <<-RUBY
          #{conversion_pair}
          [Pair.new].map { |pair| pair.class }.inspect
          RUBY
        eval(src).as_string.should eq "[Pair]"
      end
    end
  end
end
