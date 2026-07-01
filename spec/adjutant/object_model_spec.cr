require "../spec_helper"

module Adjutant
  # Helper: eval source and return the result value.
  private def self.eval(source : String) : Value
    interp, _ = make_interp
    interp.eval(source)
  end

  describe "Object model" do
    describe "class creation" do
      it "class becomes a real RubyClass, not a stub" do
        eval("class Foo\nend\nFoo").rclass?.should be_true
      end

      it "class name is set" do
        eval("class Foo\nend\nFoo").as_rclass.name.should eq "Foo"
      end

      it "class has no superclass by default" do
        eval("class Foo\nend\nFoo").as_rclass.superclass.should be_nil
      end

      it "is not a module" do
        eval("class Foo\nend\nFoo").as_rclass.is_module?.should be_false
      end
    end

    describe "module creation" do
      it "module becomes a real RubyClass tagged as a module" do
        val = eval("module M\nend\nM")
        val.rclass?.should be_true
        val.as_rclass.is_module?.should be_true
      end

      it "module has no superclass" do
        eval("module M\nend\nM").as_rclass.superclass.should be_nil
      end
    end

    describe "superclass resolution" do
      it "resolves a defined superclass" do
        val = eval("class Animal\nend\nclass Dog < Animal\nend\nDog")
        sup = val.as_rclass.superclass
        sup.should_not be_nil
        sup.not_nil!.name.should eq "Animal"
      end

      it "raises for an undefined superclass" do
        expect_raises(RuntimeError, /uninitialized constant Unknown/) do
          eval("class Dog < Unknown\nend")
        end
      end
    end

    describe "method definitions" do
      it "registers methods on the class method table, not globals" do
        val = eval("class Foo\ndef bar\n1\nend\nend\nFoo")
        cls = val.as_rclass
        cls.methods.size.should eq 1
        cls.methods.first_value.name.should eq "bar"
      end

      it "def outside a class still defines a global function as before" do
        eval("def bar\n42\nend\nbar()").as_int.should eq 42_i64
      end
    end

    describe "self inside a class body" do
      it "self is the class being defined" do
        val = eval("class Foo\n SELF_STR = self.to_s\nend\nSELF_STR")
        val.as_string.should eq "class Foo"
      end

      it "self is restored after the class body, unaffected by the body's last value" do
        val = eval("class Foo\n1 + 1\nend\nself")
        val.null?.should be_true
      end

      it "self is restored correctly across nested class definitions" do
        val = eval(<<-RB)
          class Outer
            class Inner
            end
            OUTER_SELF_STR = self.to_s
          end
          OUTER_SELF_STR
          RB
        val.as_string.should eq "class Outer"
      end
    end

    describe "instantiation (.new)" do
      it "returns a RubyObject of the right class" do
        val = eval("class Foo\nend\nFoo.new")
        val.robject?.should be_true
        val.as_robject.rclass.name.should eq "Foo"
      end

      it "works without an initialize method" do
        eval("class Foo\nend\nFoo.new").robject?.should be_true
      end

      it "runs initialize" do
        val = eval(<<-RB)
          class Foo
            def initialize
              INIT_RAN = true
            end
          end
          Foo.new
          INIT_RAN
          RB
        val.as_bool.should be_true
      end

      it "returns the new object, not initialize's return value" do
        val = eval(<<-RB)
          class Foo
            def initialize
              999
            end
          end
          Foo.new
          RB
        val.robject?.should be_true
      end

      it "raises when instantiating a module" do
        expect_raises(RuntimeError, /can't instantiate module/) do
          eval("module M\nend\nM.new")
        end
      end
    end

    describe "instance method dispatch" do
      it "calls a method defined on the instance's class" do
        val = eval("class Foo\ndef bar\n42\nend\nend\nFoo.new.bar")
        val.as_int.should eq 42_i64
      end

      it "self dispatches back to the receiver for a same-class call" do
        val = eval(<<-RB)
          class Foo
            def outer
              self.inner
            end
            def inner
              7
            end
          end
          Foo.new.outer
          RB
        val.as_int.should eq 7_i64
      end

      it "inherits methods from a superclass" do
        val = eval(<<-RB)
          class Animal
            def speak
              1
            end
          end
          class Dog < Animal
          end
          Dog.new.speak
          RB
        val.as_int.should eq 1_i64
      end

      it "a subclass method overrides the superclass method" do
        val = eval(<<-RB)
          class Animal
            def speak
              1
            end
          end
          class Dog < Animal
            def speak
              2
            end
          end
          Dog.new.speak
          RB
        val.as_int.should eq 2_i64
      end
    end

    describe "receiver-dispatch regression" do
      it "does not treat a plain positional argument as a receiver" do
        val = eval(<<-RB)
          class Foo
          end
          def identity(x)
            x
          end
          identity(Foo.new)
          RB
        val.robject?.should be_true
      end
    end
  end
end
