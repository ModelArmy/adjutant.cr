require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "assignment" do
      it "parses simple assignment" do
        node = parse_expr("x = 1")
        node.should be_a(Assign)
        node.as(Assign).target.as(Identifier).name.should eq "x"
        node.as(Assign).value.as(IntLiteral).value.should eq "1"
      end

      it "parses += compound assignment" do
        node = parse_expr("x += 1")
        node.should be_a(OpAssign)
        node.as(OpAssign).op.should eq TokenKind::Plus
      end

      it "parses ||= conditional assignment" do
        node = parse_expr("x ||= nil")
        node.should be_a(CondAssign)
        node.as(CondAssign).op.should eq TokenKind::OrAssign
      end
    end
  end
end
