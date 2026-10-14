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
        node.as(ClassNode).superclass.as(Constant).name.should eq "Dog"
      end

      it "rejects `class << self` as U014" do
        error = expect_raises(ParseError) { parse("class Greeter\n  class << self\n    def hi; end\n  end\nend") }
        error.diagnostic.not_nil!.code.should eq "U014"
      end

      it "rejects a class or module name that isn't a constant" do
        {"class foo; end", "module bar; end", "class 5; end"}.each do |source|
          error = expect_raises(ParseError) { parse(source) }
          diagnostic = error.diagnostic.not_nil!
          diagnostic.code.should eq "P001"
          diagnostic.data["expected"].should eq "a constant name"
        end
      end

      it "parses a scoped superclass as a constant path" do
        node = parse_expr("class Poodle < Pets::Dog\nend")
        node.as(ClassNode).superclass.should be_a(ConstPath)
      end

      it "parses a module definition" do
        node = parse_expr("module Greetable\nend")
        node.should be_a(ModuleNode)
        node.as(ModuleNode).name.should eq "Greetable"
      end
    end
  end
end
