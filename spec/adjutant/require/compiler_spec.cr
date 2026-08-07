require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "require" do
      it "compiles require as a Call" do
        o = ops(%{require "io"})
        o.should contain(Op::Call)
        chunk = compile(%{require "io"})
        has_require = chunk.consts.any? { |v| v.symbol? && v.as_sym.name == "require" }
        has_require.should be_true
      end
    end
  end
end
