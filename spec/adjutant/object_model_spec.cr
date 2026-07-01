require "../spec_helper"

module Adjutant
  # Helper: create an interpreter with a capturing effect handler.
  private def self.make_interp : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(effect: ef)
    {interp, ef}
  end

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
        eval("class Foo\nend\nFoo").as_rclass.is_module.should be_false
      end
    end

    describe "module creation" do
      it "module becomes a real RubyClass tagged as a module" do
        val = eval("module M\nend\nM")
        val.rclass?.should be_true
        val.as_rclass.is_module.should be_true
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
  end
end
