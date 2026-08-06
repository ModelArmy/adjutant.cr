require "../spec_helper"

module Adjutant
  describe Parser do
    describe "source position" do
      it "records line numbers" do
        node = parse_expr("42")
        node.line.should eq 1
      end

      it "records line for second-line token" do
        body = parse("foo\nbar")
        body.stmts[1].line.should eq 2
      end
    end
  end
end
