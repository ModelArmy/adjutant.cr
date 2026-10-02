require "../../spec_helper"

module Adjutant
  # Runs `src` as a method body and returns its result's `inspect`, or
  # "NameError" if it raised one.
  private def self.scope_outcome(src : String) : String
    eval(<<-RUBY).as_string
      def run_scope_case
        #{src}
      end
      begin
        run_scope_case.inspect
      rescue NameError
        "NameError"
      end
      RUBY
  end

  describe "block-local variables" do
    it "keeps a name first assigned in a block inside the block" do
      scope_outcome("[1, 2].each { |x| t = x * 2 }\nt").should eq "NameError"
    end

    it "gives each call of a block its own variable" do
      scope_outcome("[1, 2].map { |x| t ||= x; t }").should eq "[1, 2]"
    end

    it "keeps a lambda's new name inside the lambda" do
      scope_outcome("f = ->(a) { b = a }\nf.call(1)\nb").should eq "NameError"
    end

    it "still assigns an enclosing variable from a block" do
      scope_outcome("t = 0\n[1, 2].each { |x| t += x }\nt").should eq "3"
    end

    it "gives a recursive call's block its own variable" do
      eval(<<-RUBY).as_int.should eq 2
        def pick(n)
          out = nil
          [1].each { v = n; pick(n - 1) if n > 0; out = v }
          out
        end
        pick(2)
        RUBY
    end

    it "doesn't carry a block's name into a later eval" do
      interp, _ = make_interp
      interp.eval("[1].each { leaked = 5 }")
      interp.eval("begin\n  leaked\nrescue NameError\n  :gone\nend").as_sym.name.should eq "gone"
    end
  end

  describe "for loop variables" do
    it "leaves the loop variable and body names readable after the loop" do
      scope_outcome("for x in [1, 2]\n  y = x * 10\nend\n[x, y]").should eq "[2, 20]"
    end

    it "assigns an enclosing variable of the same name" do
      scope_outcome("x = 0\nfor x in [5]\nend\nx").should eq "5"
    end
  end
end
