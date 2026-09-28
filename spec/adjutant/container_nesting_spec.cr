require "../spec_helper"

# Each script here recursed once per level of nesting on the native
# stack, so it ended the host process rather than the script. Depth
# now costs heap memory, or meets `call_depth_limit` where script code
# may run at each level.
module Adjutant
  describe "Container nesting and the native stack" do
    describe "==" do
      it "compares arrays nested 100,000 deep" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = []
          b = []
          100_000.times do
            a = [a]
            b = [b]
          end
          a == b
        RUBY
        result.truthy?.should be_true
      end

      it "compares hashes nested 100,000 deep" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {}
          g = {}
          100_000.times do
            h = {"x" => h}
            g = {"x" => g}
          end
          h == g
        RUBY
        result.truthy?.should be_true
      end
    end

    describe "Hash keys" do
      it "stores and finds a self-containing array as a key" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = []
          a.push(a)
          h = {a => 1}
          h[a]
        RUBY
        result.as_int.should eq 1
      end

      it "finds a key by a distinct self-containing array of the same shape" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = []
          a.push(a)
          b = []
          b.push(b)
          h = {a => 1}
          h[b]
        RUBY
        result.as_int.should eq 1
      end

      it "stores and finds an array nested 100,000 deep as a key" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          k = []
          100_000.times { k = [k] }
          h = {k => 1}
          h[k]
        RUBY
        result.as_int.should eq 1
      end

      it "compares hashes whose keys are hashes" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = {{{} => 1} => 2}
          b = {{{} => 1} => 2}
          a == b
        RUBY
        result.truthy?.should be_true
      end

      # Matching a Hash key that is itself a container runs a walk
      # inside the walk, so a chain of Hashes each keyed by the last
      # still recurses; past a limit the run ends instead.
      it "ends the run when Hash keys nest inside Hash keys past the limit" do
        interp, _ = make_interp
        expect_raises(FatalSignal, /Hash keys nested inside Hash keys/) do
          interp.eval(<<-RUBY)
            a = {}
            b = {}
            100_000.times do
              a = {a => 1}
              b = {b => 1}
            end
            a == b
          RUBY
        end
      end

      it "still tells keys apart that differ below the first level" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          h = {[[1]] => "one", [[2]] => "two"}
          [h[[[1]]], h[[[2]]], h.size]
        RUBY
        result.as_array.to_a.map(&.to_s).should eq ["one", "two", "2"]
      end
    end

    describe "call_depth_limit through native code" do
      it "stops recursion that passes through a block run by each" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) do
          interp.eval(<<-RUBY)
            def down(n)
              [n].each { down(n + 1) }
            end
            down(0)
          RUBY
        end
        error.diagnostic.not_nil!.code.should eq "L002"
      end

      it "stops inspect of an array nested deeper than the limit" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) do
          interp.eval(<<-RUBY)
            a = []
            100_000.times { a = [a] }
            a.inspect
          RUBY
        end
        error.diagnostic.not_nil!.code.should eq "L002"
      end

      it "still inspects nesting within the limit" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          a = []
          3.times { a = [a] }
          a.inspect
        RUBY
        result.as_string.should eq "[[[[]]]]"
      end
    end
  end
end
