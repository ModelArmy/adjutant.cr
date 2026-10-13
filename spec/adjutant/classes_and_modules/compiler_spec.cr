require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "class and module" do
      it "compiles a class with MakeClass" do
        ops("class Dog\nend").should contain(Op::MakeClass)
      end

      it "compiles a module with MakeModule" do
        ops("module Greetable\nend").should contain(Op::MakeModule)
      end

      it "computes the superclass onto the stack for MakeClass" do
        chunk = compile("class Poodle < Dog\nend")
        inst = chunk.code.find { |i| i.op == Op::MakeClass }.not_nil!
        inst.b.should eq Compiler::SUPER_ON_STACK
      end

      it "uses NO_SUPER sentinel when no superclass" do
        chunk = compile("class Dog\nend")
        inst = chunk.code.find { |i| i.op == Op::MakeClass }.not_nil!
        inst.b.should eq Compiler::NO_SUPER
      end
    end
  end
end
