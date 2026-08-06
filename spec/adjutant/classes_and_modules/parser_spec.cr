require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "class and module" do
      it "parses a class definition" do
        node = parse_expr("class Dog\nend")
        node.should be_a(ClassNode)
        node.as(ClassNode).name.should eq "Dog"
      end

      it "parses a class with superclass" do
        node = parse_expr("class Poodle < Dog\nend")
        node.as(ClassNode).superclass.should eq "Dog"
      end

      it "parses a module definition" do
        node = parse_expr("module Greetable\nend")
        node.should be_a(ModuleNode)
        node.as(ModuleNode).name.should eq "Greetable"
      end
    end
  end
end
