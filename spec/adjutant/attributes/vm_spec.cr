require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "attr_reader / attr_writer / attr_accessor" do
      it "attr_reader defines a getter that reads the ivar" do
        val = eval(<<-RUBY)
          class Point
            attr_reader :x
            def initialize(x)
              @x = x
            end
          end
          Point.new(5).x
          RUBY
        val.as_int.should eq 5_i64
      end

      it "attr_reader does not also define a setter" do
        expect_raises(RuntimeError) do
          eval(<<-RUBY)
            class Point
              attr_reader :x
              def initialize(x)
                @x = x
              end
            end
            Point.new(1).x = 2
            RUBY
        end
      end

      it "attr_writer defines a setter that writes the ivar" do
        val = eval(<<-RUBY)
          class Box
            attr_writer :value
            def peek
              @value
            end
          end
          b = Box.new
          b.value = 7
          b.peek
          RUBY
        val.as_int.should eq 7_i64
      end

      it "attr_writer does not also define a getter" do
        expect_raises(RuntimeError) do
          eval(<<-RUBY)
            class Box
              attr_writer :value
            end
            Box.new.value
            RUBY
        end
      end

      it "attr_accessor defines both a getter and a setter" do
        val = eval(<<-RUBY)
          class Point
            attr_accessor :x
            def initialize(x)
              @x = x
            end
          end
          p = Point.new(1)
          p.x = 99
          p.x
          RUBY
        val.as_int.should eq 99_i64
      end

      it "attr_accessor with multiple names defines independent accessors for each" do
        val = eval(<<-RUBY)
          class Point
            attr_accessor :x, :y
            def initialize(x, y)
              @x = x
              @y = y
            end
          end
          p = Point.new(1, 2)
          p.x = 10
          p.y = 20
          [p.x, p.y]
          RUBY
        arr = val.as_array
        arr[0].as_int.should eq 10_i64
        arr[1].as_int.should eq 20_i64
      end

      it "accepts optional parens, same as a real method call" do
        val = eval(<<-RUBY)
          class Tag
            attr_accessor(:label)
            def initialize(label)
              @label = label
            end
          end
          Tag.new("hi").label
          RUBY
        val.as_string.should eq "hi"
      end
    end
  end
end
