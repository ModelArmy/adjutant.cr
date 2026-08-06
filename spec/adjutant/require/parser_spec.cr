require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "require" do
      it "parses require" do
        node = parse_expr(%{require "io"})
        node.should be_a(RequireNode)
        node.as(RequireNode).path.as(StringLiteral).value.should eq "io"
      end
    end
  end
end
