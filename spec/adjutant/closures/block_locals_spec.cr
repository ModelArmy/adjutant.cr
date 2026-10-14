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

  describe "loop body variables" do
    it "gives a name first assigned in the body a new value on each iteration" do
      scope_outcome("acc = []\nn = 0\nloop do\n  x ||= 0\n  x += 1\n  acc << x\n  n += 1\n  break if n == 3\nend\nacc").should eq "[1, 1, 1]"
    end

    it "ends a name first assigned in the body with the loop" do
      scope_outcome("loop do\n  inner = 1\n  break\nend\ninner").should eq "NameError"
    end

    it "assigns a variable from before the loop" do
      scope_outcome("x = 5\nloop do\n  x += 1\n  break\nend\nx").should eq "6"
    end

    it "leaves the method on return" do
      scope_outcome("loop do\n  return :out\nend\n:never").should eq ":out"
    end
  end

  describe "redo outside a loop" do
    it "restarts a block's body" do
      scope_outcome("a = []\n[1].each do |v|\n  a << v\n  if a.size < 2\n    redo\n  end\nend\na").should eq "[1, 1]"
    end

    it "restarts a lambda's body" do
      scope_outcome("a = []\n-> {\n  a << 1\n  if a.size < 2\n    redo\n  end\n}.call\na").should eq "[1, 1]"
    end

    it "restarts a for body's iteration" do
      scope_outcome("j = 0\nfor i in 1..3\n  j += i\n  if i == 2 && j < 4\n    redo\n  end\nend\nj").should eq "8"
    end
  end

  describe "for loop variables" do
    it "leaves the loop variable and body names readable after the loop" do
      scope_outcome("for x in [1, 2]\n  y = x * 10\nend\n[x, y]").should eq "[2, 20]"
    end

    it "assigns an enclosing variable of the same name" do
      scope_outcome("x = 0\nfor x in [5]\nend\nx").should eq "5"
    end

    it "assigns an instance variable target" do
      scope_outcome("for @x in [1, 2]\nend\n@x").should eq "2"
    end

    it "assigns an index target" do
      scope_outcome("a = [0, 0]\nfor a[1] in [1, 2]\nend\na").should eq "[0, 2]"
    end

    it "assigns a class variable target" do
      result = eval(<<-RUBY)
        class ForTarget
          @@v = 0
          def self.run
            for @@v in [1, 2]
            end
            @@v
          end
        end
        ForTarget.run
      RUBY
      result.should eq Value.int(2_i64)
    end

    it "rejects an attribute target, which a multiple assignment can't take either" do
      error = expect_raises(CompileError) { compile("o = 1\nfor o.t in [1]\nend") }
      error.diagnostic.not_nil!.code.should eq "C001"
    end
  end
end
