require "../../spec_helper"

module Adjutant
  # The code of the CompileError `source` raises, or "compiled".
  private def self.jump_compile_code(source : String) : String
    eval(source)
    "compiled"
  rescue ex : CompileError
    ex.diagnostic.not_nil!.code
  end

  describe "rescue with an expression" do
    it "matches the class a local variable holds" do
      eval(<<-RUBY).as_string.should eq "outer"
        k = ArgumentError
        begin
          begin
            raise TypeError, "t"
          rescue k
            "inner"
          end
        rescue TypeError
          "outer"
        end
        RUBY
    end

    it "binds with `=>` after an expression" do
      eval(%(k = RuntimeError\nbegin\n  raise "m"\nrescue k => err\n  err.message\nend)).as_string.should eq "m"
    end

    it "raises NameError for an undefined name, when an error is matched" do
      eval(<<-RUBY).as_string.should eq "NameError"
        begin
          begin
            raise "x"
          rescue e
            "inner"
          end
        rescue NameError
          "NameError"
        end
        RUBY
    end

    it "raises TypeError for a value that isn't a class" do
      eval(<<-RUBY).as_string.should eq "TypeError"
        n = 5
        begin
          begin
            raise "x"
          rescue n
            "inner"
          end
        rescue TypeError
          "TypeError"
        end
        RUBY
    end

    it "assigns an enclosing variable from `=> e` inside a block, as an ordinary assignment" do
      eval(<<-RUBY).as_bool.should be_true
        e = :before
        [1].each do
          begin
            raise "boom"
          rescue => e
          end
        end
        e.is_a?(RuntimeError)
        RUBY
    end

    it "keeps a new `=> err` inside the block" do
      eval(<<-RUBY).as_string.should eq "NameError"
        [1].each do
          begin
            raise "boom"
          rescue => err
          end
        end
        begin
          err
        rescue NameError
          "NameError"
        end
        RUBY
    end

    it "makes is_a? raise TypeError for a value that isn't a class" do
      eval(%(begin\n  5.is_a?(3)\nrescue TypeError\n  "TypeError"\nend)).as_string.should eq "TypeError"
    end
  end

  describe "break and next outside a loop or block" do
    it "rejects them in a method body or at top level (C003)" do
      jump_compile_code("def f\n  break\nend").should eq "C003"
      jump_compile_code("def f\n  next\nend").should eq "C003"
      jump_compile_code("break").should eq "C003"
    end

    it "allows them in a block or loop" do
      eval("def f\n  [1, 2].each { |x| break x * 10 }\nend\nf").as_int.should eq 10
      eval("i = 0\nwhile true\n  i += 1\n  break if i > 2\nend\ni").as_int.should eq 3
    end
  end
end
