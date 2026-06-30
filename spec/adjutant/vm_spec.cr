require "../spec_helper"

module Adjutant
  # Helper: create an interpreter with a capturing effect handler.
  private def self.make_interp(limits : ExecutionLimits = ExecutionLimits.new) : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(effect: ef, limits: limits)
    {interp, ef}
  end

  # Helper: create an interpreter and register a module.
  private def self.make_interp_with_module(name : String, &block : Interpreter -> Nil) : {Interpreter, TestEffectHandler}
    interp, ef = make_interp
    interp.modules.register(name) { |i| block.call(i) }
    {interp, ef}
  end

  # Helper: eval source and return the result value.
  private def self.eval(source : String) : Value
    interp, _ = make_interp
    interp.eval(source)
  end

  describe Interpreter do
    describe "literals" do
      it "evaluates nil" do
        eval("nil").null?.should be_true
      end

      it "evaluates true" do
        eval("true").as_bool.should be_true
      end

      it "evaluates false" do
        eval("false").as_bool.should be_false
      end

      it "evaluates an integer" do
        eval("42").as_int.should eq 42_i64
      end

      it "evaluates a float" do
        eval("3.14").as_float.should be_close(3.14, 1e-10)
      end

      it "evaluates a string" do
        eval(%("hello")).as_string.should eq "hello"
      end

      it "evaluates a symbol" do
        v = eval(":ok")
        v.symbol?.should be_true
        v.as_sym.name.should eq "ok"
      end

      it "evaluates an array literal" do
        v = eval("[1, 2, 3]")
        v.array?.should be_true
        v.as_array.size.should eq 3
      end

      it "evaluates a hash literal" do
        v = eval(%({ "a" => 1 }))
        v.hash?.should be_true
        v.as_hash.size.should eq 1
      end
    end

    describe "arithmetic" do
      it "adds integers" do
        eval("1 + 2").as_int.should eq 3_i64
      end

      it "subtracts integers" do
        eval("5 - 3").as_int.should eq 2_i64
      end

      it "multiplies integers" do
        eval("3 * 4").as_int.should eq 12_i64
      end

      it "divides integers (floor)" do
        eval("7 / 2").as_int.should eq 3_i64
      end

      it "computes modulo" do
        eval("7 % 3").as_int.should eq 1_i64
      end

      it "adds floats" do
        eval("1.5 + 2.5").as_float.should be_close(4.0, 1e-10)
      end

      it "promotes int+float to float" do
        eval("1 + 2.5").as_float.should be_close(3.5, 1e-10)
      end

      it "concatenates strings with +" do
        eval(%("hello" + " world")).as_string.should eq "hello world"
      end

      it "negates an integer" do
        eval("-7").as_int.should eq -7_i64
      end

      it "raises on divide by zero" do
        expect_raises(RuntimeError) { eval("1 / 0") }
      end
    end

    describe "comparison" do
      it "compares integers with ==" do
        eval("1 == 1").as_bool.should be_true
        eval("1 == 2").as_bool.should be_false
      end

      it "compares integers with !=" do
        eval("1 != 2").as_bool.should be_true
      end

      it "compares integers with <" do
        eval("1 < 2").as_bool.should be_true
        eval("2 < 1").as_bool.should be_false
      end

      it "compares integers with <=" do
        eval("2 <= 2").as_bool.should be_true
      end

      it "compares integers with >" do
        eval("3 > 2").as_bool.should be_true
      end

      it "compares nil == nil" do
        eval("nil == nil").as_bool.should be_true
      end

      it "compares symbols by identity" do
        eval(":foo == :foo").as_bool.should be_true
        eval(":foo == :bar").as_bool.should be_false
      end
    end

    describe "boolean logic" do
      it "short-circuits ||" do
        eval("true || false").as_bool.should be_true
        eval("false || true").as_bool.should be_true
      end

      it "short-circuits &&" do
        eval("true && false").as_bool.should be_false
        eval("true && true").as_bool.should be_true
      end

      it "negates with !" do
        eval("!true").as_bool.should be_false
        eval("!false").as_bool.should be_true
        eval("!nil").as_bool.should be_true
      end
    end

    describe "variables" do
      it "assigns and reads a variable" do
        eval("x = 42\nx").as_int.should eq 42_i64
      end

      it "reassigns a variable" do
        eval("x = 1\nx = 2\nx").as_int.should eq 2_i64
      end

      it "evaluates compound assignment +=" do
        eval("x = 10\nx += 5\nx").as_int.should eq 15_i64
      end

      it "evaluates ||= when nil" do
        eval("x = nil\nx ||= 42\nx").as_int.should eq 42_i64
      end

      it "evaluates ||= when already set" do
        eval("x = 1\nx ||= 99\nx").as_int.should eq 1_i64
      end
    end

    describe "string interpolation" do
      it "interpolates an integer" do
        eval(%("value: \#{42}")).as_string.should eq "value: 42"
      end

      it "interpolates a variable" do
        eval(%(x = "world"\n"hello \#{x}")).as_string.should eq "hello world"
      end
    end

    describe "indexing" do
      it "indexes into an array" do
        eval("[10, 20, 30][1]").as_int.should eq 20_i64
      end

      it "indexes with negative index" do
        eval("[1, 2, 3][-1]").as_int.should eq 3_i64
      end

      it "assigns to an array index" do
        eval("a = [1, 2, 3]\na[0] = 99\na[0]").as_int.should eq 99_i64
      end

      it "indexes into a hash" do
        eval(%({ "k" => 42 }["k"])).as_int.should eq 42_i64
      end
    end

    describe "control flow" do
      it "evaluates if-then" do
        eval("if true\n42\nend").as_int.should eq 42_i64
      end

      it "evaluates the else branch" do
        eval("if false\n1\nelse\n2\nend").as_int.should eq 2_i64
      end

      it "evaluates elsif" do
        eval("x = 2\nif x == 1\n:one\nelsif x == 2\n:two\nelse\n:other\nend").as_sym.name.should eq "two"
      end

      it "evaluates unless" do
        eval("unless false\n:yes\nend").as_sym.name.should eq "yes"
      end

      it "evaluates ternary" do
        eval("1 > 0 ? :yes : :no").as_sym.name.should eq "yes"
      end

      it "evaluates a while loop" do
        eval("x = 0\nwhile x < 3\nx += 1\nend\nx").as_int.should eq 3_i64
      end

      it "evaluates modifier if" do
        eval("x = 1\nx = 2 if true\nx").as_int.should eq 2_i64
      end

      it "evaluates modifier unless" do
        eval("x = 1\nx = 2 unless false\nx").as_int.should eq 2_i64
      end
    end

    describe "effect handler" do
      it "captures puts output" do
        interp, ef = make_interp
        interp.eval(%{puts("hello")})
        ef.stdout.should eq "hello\n"
      end

      it "captures multiple puts calls" do
        interp, ef = make_interp
        interp.eval("puts(1)\nputs(2)")
        ef.stdout_log.size.should eq 2
      end

      it "captures print without newline" do
        interp, ef = make_interp
        interp.eval(%{print("hi")})
        ef.stdout.should eq "hi"
      end
    end

    describe "execution limits" do
      it "raises when instruction limit exceeded" do
        limits = ExecutionLimits.new(instruction_limit: 5_u64)
        interp, _ = make_interp(limits)
        expect_raises(RuntimeError, /instruction limit/) do
          interp.eval("x = 0\nwhile true\nx += 1\nend")
        end
      end

      it "stores the call depth limit" do
        # Full call depth enforcement requires wired def/call (Phase 6).
        # Verify the limit is stored and accessible.
        limits = ExecutionLimits.new(call_depth_limit: 3)
        interp, _ = make_interp(limits)
        interp.limits.call_depth_limit.should eq 3
      end
    end

    describe "require via VFS" do
      it "loads a script file from the VFS" do
        interp, ef = make_interp
        ef.add_file("greet.rb", %(x = "hello from vfs"))
        interp.eval(%(require "greet.rb"))
        interp.get_global("x").as_string.should eq "hello from vfs"
      end

      it "raises when file not found" do
        interp, _ = make_interp
        expect_raises(RuntimeError, /cannot load/) do
          interp.eval(%(require "missing.rb"))
        end
      end

      it "loads a registered script module" do
        interp, _ = make_interp
        interp.modules.register("agent/math") do |i|
          i.define_native("double") { |args| Value.int(args.first.as_int * 2) }
        end
        interp.eval(%(require "agent/math"\ndouble(5))).as_int.should eq 10_i64
      end

      it "loads each module only once" do
        count = 0
        interp, _ = make_interp
        interp.modules.register("once") { |_| count += 1 }
        interp.eval(%(require "once"\nrequire "once"))
        count.should eq 1
      end
    end

    describe "native functions" do
      it "calls a native function registered via define_native" do
        interp, _ = make_interp
        interp.define_native("double") { |args| Value.int(args.first.as_int * 2) }
        interp.eval("double(21)").as_int.should eq 42_i64
      end

      it "calls a native function exposed via a script module" do
        interp, _ = make_interp
        interp.modules.register("mylib") do |i|
          i.define_native("triple") { |args| Value.int(args.first.as_int * 3) }
        end
        interp.eval("require \"mylib\"\ntriple(7)").as_int.should eq 21_i64
      end
    end

    describe "shared symbol table across evals" do
      it "retains variables across multiple evals" do
        interp, _ = make_interp
        interp.eval("x = 10")
        result = interp.eval("x + 5")
        result.as_int.should eq 15_i64
      end

      it "shares symbol IDs across compilations" do
        interp, _ = make_interp
        interp.eval(":shared")
        id1 = interp.symbols.intern("shared").value
        interp.eval(":shared")
        id2 = interp.symbols.intern("shared").value
        id1.should eq id2
      end
    end

    describe "methods and closures" do
      it "calls a def with params" do
        src = <<-RUBY
        def add(a, b)
          a + b
        end
        add(3, 4)
        RUBY
        eval(src).as_int.should eq 7_i64
      end

      it "isolates method locals from global scope" do
        src = <<-RUBY
        x = 1
        def set_x
          x = 99
        end
        set_x
        x
        RUBY
        eval(src).as_int.should eq 1_i64
      end

      it "evaluates a recursive method" do
        src = <<-RUBY
        def fact(n)
          return 1 if n < 2
          n * fact(n - 1)
        end
        fact(5)
        RUBY
        eval(src).as_int.should eq 120_i64
      end

      it "supports multiple params" do
        src = <<-RUBY
        def greet(a, b, c)
          a + b + c
        end
        greet(1, 2, 3)
        RUBY
        eval(src).as_int.should eq 6_i64
      end

      it "supports local variables inside a method" do
        src = <<-RUBY
        def double(n)
          result = n * 2
          result
        end
        double(21)
        RUBY
        eval(src).as_int.should eq 42_i64
      end

      it "supports default-nil return when body is empty" do
        src = <<-RUBY
        def noop()
        end
        noop()
        RUBY
        eval(src).null?.should be_true
      end

      it "yields to a block" do
        src = <<-RUBY
        def call_block
          yield 10
        end
        call_block { |x| x * 2 }
        RUBY
        eval(src).as_int.should eq 20_i64
      end

      it "block does not capture enclosing local via closure" do
        src = <<-RUBY
        def run
          total = 0
          yield 1
          yield 2
          yield 3
          total
        end
        run { |x| total += x }
        RUBY
        expect_raises(Adjutant::RuntimeError) do
          eval(src)
        end
      end

      it "block captures local from its defining scope via yield" do
        src = <<-RUBY
        total = 0
        def apply
          yield 1
          yield 2
          yield 3
        end
        apply { |x| total += x }
        total
        RUBY
        eval(src).as_int.should eq 6_i64
      end
      it "computes fibonacci recursively" do
        src = <<-RUBY
        def fib(n)
          return n if n < 2
          fib(n - 1) + fib(n - 2)
        end
        fib(3)
        RUBY
        eval(src).as_int.should eq 2_i64
      end

      it "return value accumulates across calls" do
        interp, _ = make_interp
        interp.eval("total = 0")
        src = <<-RUBY
        def add_one(n)
          n + 1
        end
        RUBY
        interp.eval(src)
        src = <<-RUBY
        total = add_one(total)
        total = add_one(total)
        total = add_one(total)
        RUBY
        interp.eval(src)
        interp.get_global("total").as_int.should eq 3_i64
      end
    end

    describe "realistic programs" do
      it "computes fibonacci iteratively" do
        src = <<-RUBY
          a = 0
          b = 1
          i = 0
          while i < 10
            tmp = a + b
            a = b
            b = tmp
            i += 1
          end
          a
        RUBY
        # fib(10) = 55
        eval(src).as_int.should eq 55_i64
      end

      it "sums an array" do
        src = <<-RUBY
        arr = [1, 2, 3, 4, 5]
        sum = 0
        i = 0
        while i < 5
          sum += arr[i]
          i += 1
        end
        sum
        RUBY
        eval(src).as_int.should eq 15_i64
      end
    end
  end
end
