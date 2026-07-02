require "../spec_helper"

module Adjutant
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
        val = eval("class Foo\n SELF_STR = self.to_s\nend\nFoo::SELF_STR")
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
          Outer::OUTER_SELF_STR
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
          Foo::INIT_RAN
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

    describe "instance variables" do
      it "sets and reads an ivar on self via a method" do
        val = eval(<<-RB)
          class Foo
            def set
              @x = 5
            end
            def get
              @x
            end
          end
          f = Foo.new
          f.set
          f.get
          RB
        val.as_int.should eq 5_i64
      end

      it "ivars are set via initialize" do
        val = eval(<<-RB)
          class Foo
            def initialize(v)
              @x = v
            end
            def get
              @x
            end
          end
          Foo.new(9).get
          RB
        val.as_int.should eq 9_i64
      end

      it "ivars are isolated per instance" do
        val = eval(<<-RB)
          class Foo
            def set(v)
              @x = v
            end
            def get
              @x
            end
          end
          a = Foo.new
          b = Foo.new
          a.set(1)
          b.set(2)
          a.get
          RB
        val.as_int.should eq 1_i64
      end

      it "unset ivar reads as nil" do
        val = eval(<<-RB)
          class Foo
            def get
              @unset
            end
          end
          Foo.new.get
          RB
        val.null?.should be_true
      end

      it "ivar outside an object silently reads as nil" do
        eval("@x").null?.should be_true
      end
    end

    describe "class variables" do
      it "sets and reads a cvar from an instance method" do
        val = eval(<<-RB)
          class Foo
            def set
              @@count = 1
            end
            def get
              @@count
            end
          end
          f = Foo.new
          f.set
          f.get
          RB
        val.as_int.should eq 1_i64
      end

      it "cvars are shared across instances" do
        val = eval(<<-RB)
          class Foo
            def bump
              @@count = (@@count || 0) + 1
            end
            def get
              @@count
            end
          end
          a = Foo.new
          b = Foo.new
          a.bump
          b.bump
          a.get
          RB
        val.as_int.should eq 2_i64
      end

      it "a subclass reads the superclass's cvar" do
        val = eval(<<-RB)
          class Animal
            @@kind = 1
            def kind
              @@kind
            end
          end
          class Dog < Animal
          end
          Dog.new.kind
          RB
        val.as_int.should eq 1_i64
      end

      it "a subclass write updates the shared superclass cvar" do
        val = eval(<<-RB)
          class Animal
            @@kind = 1
            def get
              @@kind
            end
          end
          class Dog < Animal
            def set
              @@kind = 2
            end
          end
          d = Dog.new
          d.set
          Animal.new.get
          RB
        val.as_int.should eq 2_i64
      end

      it "raises for cvar access outside a class context" do
        expect_raises(RuntimeError, /class variable access outside/) do
          eval("@@x")
        end
      end
    end

    describe "constants" do
      it "a top-level constant is globally visible" do
        eval("MYCONST = 5\nMYCONST").as_int.should eq 5_i64
      end

      it "a constant defined inside a class is scoped to that class" do
        val = eval(<<-RB)
          class A
            MYCONST = 3
          end
          A::MYCONST
          RB
        val.as_int.should eq 3_i64
      end

      it "a class-scoped constant does not leak to the top level" do
        expect_raises(RuntimeError, /uninitialized constant/) do
          eval("class A\nMYCONST = 3\nend\nMYCONST")
        end
      end

      it "resolves a doubly-nested constant via an explicit path" do
        val = eval(<<-RB)
          class A
            class B
              MYCONST = 7
            end
          end
          A::B::MYCONST
          RB
        val.as_int.should eq 7_i64
      end

      it "a method sees the constant lexically nested at its own def site, not an outer shadowed one" do
        val = eval(<<-RB)
          class A
            MYCONST = 3
            class B
              MYCONST = 4
              def x
                MYCONST
              end
            end
          end
          A::B.new.x
          RB
        val.as_int.should eq 4_i64
      end

      it "a method falls back to an outer lexical constant when its own scope doesn't define one" do
        val = eval(<<-RB)
          class A
            MYCONST = 3
            class B
              def x
                MYCONST
              end
            end
          end
          A::B.new.x
          RB
        val.as_int.should eq 3_i64
      end

      it "constant lookup is lexical, not based on the superclass chain" do
        expect_raises(RuntimeError, /uninitialized constant/) do
          eval(<<-RB)
            class Animal
              MYCONST = 1
            end
            class Dog < Animal
              def get
                MYCONST
              end
            end
            Dog.new.get
            RB
        end
      end

      it "raises for a totally undefined constant" do
        expect_raises(RuntimeError, /uninitialized constant/) do
          eval("NOPE")
        end
      end
    end
  end
end
