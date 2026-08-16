require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "Object#to_s — real, overridable, default unchanged" do
      it "a plain object with no override still renders as #<ClassName> via to_s" do
        eval(<<-RUBY).should eq Value.string("#<A>")
        class A
        end
        A.new.to_s
        RUBY
      end

      it "a script class's own `def to_s` is used instead of the default" do
        eval(<<-RUBY).should eq Value.string("custom!")
        class A
          def to_s
            "custom!"
          end
        end
        A.new.to_s
        RUBY
      end
    end

    describe "Object#inspect — real, default lists ivars" do
      it "a plain object with no ivars renders the same as its to_s" do
        eval(<<-RUBY).should eq Value.string("#<A>")
        class A
        end
        A.new.inspect
        RUBY
      end

      it "an object with ivars lists them, insertion order, ivar values inspected recursively" do
        eval(<<-RUBY).should eq Value.string(%(#<A @x=1, @y="hi">))
        class A
          def initialize
            @x = 1
            @y = "hi"
          end
        end
        A.new.inspect
        RUBY
      end

      it "inspect does NOT consult a script's own to_s override — real Ruby's default #inspect ignores #to_s entirely" do
        eval(<<-RUBY).should eq Value.string("#<A>")
        class A
          def to_s
            "custom!"
          end
        end
        A.new.inspect
        RUBY
      end

      it "a nested ivar's own class inspect is respected recursively (via real dispatch, not hand-rolled recursion)" do
        eval(<<-RUBY).should eq Value.string(%(#<Outer @inner=#<Inner @label="hi">>))
        class Inner
          def initialize
            @label = "hi"
          end
        end
        class Outer
          def initialize
            @inner = Inner.new
          end
        end
        Outer.new.inspect
        RUBY
      end

      it "primitives fall back to the existing Value#inspect, unaffected by Object's new default (no crash on a non-RubyObject receiver)" do
        eval("5.inspect").should eq Value.string("5")
        eval(%("hi".inspect)).should eq Value.string(%("hi"))
        eval("nil.inspect").should eq Value.string("nil")
        eval(":sym.inspect").should eq Value.string(":sym")
        eval("true.inspect").should eq Value.string("true")
      end
    end

    describe "string interpolation now uses real dispatch for to_s (Op::Concat)" do
      it "a script class's own `def to_s` is respected inside interpolation — the actual step 1 fix" do
        eval(<<-RUBY).should eq Value.string("value: custom!")
        class A
          def to_s
            "custom!"
          end
        end
        "value: \#{A.new}"
        RUBY
      end

      it "a plain object with no override still interpolates as #<ClassName>, unchanged" do
        eval(<<-RUBY).should eq Value.string("got: #<A>")
        class A
        end
        "got: \#{A.new}"
        RUBY
      end

      it "scalars still interpolate via the fast path, unaffected" do
        eval(%("\#{1} \#{1.5} \#{true} \#{nil} \#{:sym} \#{"str"}")).should eq Value.string("1 1.5 true  sym str")
      end

      it "a Range now interpolates via its OWN real to_s — a pre-existing implicit-path bug fixed as a side effect of routing through real dispatch" do
        eval(%("range: \#{1..3}")).should eq Value.string("range: 1..3")
      end

      it "a class value still interpolates as its qualified name, unaffected (RubyClass stays on the fast path)" do
        eval(<<-RUBY).should eq Value.string("class: A")
        class A
        end
        "class: \#{A}"
        RUBY
      end
    end
  end
end
