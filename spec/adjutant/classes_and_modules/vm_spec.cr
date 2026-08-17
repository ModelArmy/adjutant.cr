require "../../spec_helper"

module Adjutant
  describe Interpreter do
    # Op::SetConstant hardening, added 2026-07-18 ahead of Piece D (see
    # SCOPE.md): real Ruby only WARNS on constant reassignment (still
    # permits it); Adjutant deliberately makes it a hard error, so a
    # constant-valued Lambda passed as a call argument can be trusted
    # to be staticaly resolvable by RiskWalker — nothing else in the
    # same script could have quietly reassigned it first. Covers both
    # branches of Op::SetConstant's target-vs-@globals split: a
    # top-level `FOO = 1` (target is nil — main is a RubyObject, not a
    # RubyClass, and top-level code has no lexical_scope) and a
    # constant defined inside a class/module body (target is that
    # RubyClass, via target.constants) both need the same guard; this
    # was a real bug in an earlier draft of the fix (the guard was
    # first written narrowly, only catching @globals-routed
    # reassignment for rclass-valued — i.e. class-name — constants,
    # which would have silently let a plain top-level `FOO = 1; FOO =
    # 2` back through).
    describe "constants" do
      it "a plain top-level constant assigned once works normally" do
        eval("FOO = 1\nFOO").as_int.should eq 1
      end

      it "reassigning a plain top-level constant raises" do
        expect_raises(RuntimeError, /already initialized/) do
          eval("FOO = 1\nFOO = 2")
        end
      end

      it "reassigning a constant defined inside a class body raises" do
        expect_raises(RuntimeError, /already initialized/) do
          eval(<<-RUBY)
          class Foo
            BAR = 1
            BAR = 2
          end
          RUBY
        end
      end

      it "the same constant name in two DIFFERENT classes does not collide" do
        # target.constants is per-RubyClass — Foo::BAR and Baz::BAR are
        # unrelated slots, confirming the guard checks the right Hash,
        # not some shared/global one.
        result = eval(<<-RUBY)
        class Foo
          BAR = 1
        end
        class Baz
          BAR = 2
        end
        [Foo::BAR, Baz::BAR]
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2]
      end

      it "defining a class once works normally" do
        eval(<<-RUBY).as_int.should eq 5
        class Foo
          def five; 5; end
        end
        Foo.new.five
        RUBY
      end

      it "reopening (redefining) a class raises rather than silently discarding the first body" do
        # Previously: Op::MakeClass always allocated a fresh,
        # disconnected RubyClass and Op::SetConstant just overwrote the
        # constant slot — `five` from the first body was silently
        # lost, not a compile/runtime error. See UNSUPPORTED.md's U003,
        # class/module reopening, for why real reopening isn't being
        # built instead.
        # Reports as U003 (reopening) rather than the generic
        # constant-reassignment fault: both come from the same
        # assign-once guard, but a reader who reopened a class needs to
        # know that construct is never coming, not that some constant
        # rule fired. Asserting on the code, which is stable, rather
        # than the wording, which is not.
        error = expect_raises(RuntimeError) do
          eval(<<-RUBY)
          class Foo
            def five; 5; end
          end
          class Foo
            def six; 6; end
          end
          RUBY
        end
        error.diagnostic.not_nil!.code.should eq("U003")
      end

      it "reopening a builtin class also raises, same policy" do
        # Builtin classes (Integer, String, Array, ...) are registered
        # into the same @globals constant space as script-defined ones
        # during Interpreter bootstrap (see
        # Interpreter#define_global_class) — so this is the SAME
        # SetConstant path and guard, not a special case. Real Ruby's
        # most common reopening use case (monkey-patching a builtin) is
        # therefore also a hard error now, consistent with the
        # deliberate scope decision (UNSUPPORTED.md, U003), not an
        # oversight.
        error = expect_raises(RuntimeError) do
          eval(<<-RUBY)
          class String
            def shout; upcase; end
          end
          RUBY
        end
        error.diagnostic.not_nil!.code.should eq("U003")
      end

      it "distinguishes an ordinary constant reassignment from a reopen" do
        # Same guard, two different problems — the message used to
        # conflate them, telling a script that had merely written
        # `FOO = 1` twice about redefining classes.
        error = expect_raises(RuntimeError) do
          eval("FOO = 1\nFOO = 2")
        end
        error.diagnostic.not_nil!.code.should eq("R001")
      end

      it "attributes a native function's own failure to the native layer" do
        # N001 exists so the provenance is unambiguous: Adjutant cannot
        # tell whether the script passed something bad or the host's
        # function is broken, and an R code would imply it had decided.
        interp, _ = make_interp
        interp.define_native("explode") { |_args| raise "boom" }
        error = expect_raises(RuntimeError) { interp.eval("explode") }
        diag = error.diagnostic.not_nil!
        diag.code.should eq("N001")
        diag.data["function"].should eq("explode")
        diag.data["message"].should eq("boom")
      end

      it "reports a deliberately excluded method as excluded, not undefined" do
        # The point of the whole exercise: "undefined" invites a retry
        # with a variation, and every variation fails identically.
        {"send" => "U005", "public_send" => "U005", "__send__" => "U005",
         "method_missing" => "U005", "define_method" => "U005",
         "eval" => "U006", "instance_eval" => "U006", "class_eval" => "U006",
         "module_eval" => "U006", "instance_exec" => "U006", "class_exec" => "U006"}.each do |name, code|
          error = expect_raises(RuntimeError) { eval(name) }
          diag = error.diagnostic.not_nil!
          diag.code.should eq(code)
          diag.data["construct"].should eq(name)
        end
      end

      it "lets a script define its own method that shares an excluded name" do
        # This is why the check happens after resolution rather than at
        # compile time. `class Mailer; def send; end; end` is valid Ruby
        # and must stay valid here.
        eval(<<-RUBY).as_string.should eq("delivered")
          class Mailer
            def send
              "delivered"
            end
          end
          Mailer.new.send
        RUBY
      end

      it "still reports an ordinary unknown name as merely undefined" do
        # The contrast that makes the distinction meaningful — an
        # excluded name is permanent, a typo is not.
        error = expect_raises(RuntimeError) { eval("no_such_thing") }
        error.diagnostic.not_nil!.code.should eq("R008")
      end

      it "reports an excluded constant as excluded, not uninitialized" do
        error = expect_raises(RuntimeError) { eval("ObjectSpace") }
        diag = error.diagnostic.not_nil!
        diag.code.should eq("U007")
        diag.data["construct"].should eq("ObjectSpace")
      end

      it "stays rescuable as a NameError, like any unresolved name" do
        # From the script's side the name genuinely does not resolve, so
        # a script rescuing NameError should still catch it. The code is
        # what says it will never resolve.
        eval(<<-RUBY).as_string.should eq("caught")
          begin
            send(:anything)
          rescue NameError
            "caught"
          end
        RUBY
      end

      it "keeps NameError as the rescuable class for R008" do
        # The diagnostic code and the script-visible class are set
        # independently: R008 classifies the failure for the reader,
        # while NameError is what real Ruby raises and therefore what a
        # script must be able to rescue.
        error = expect_raises(RuntimeError) do
          eval("no_such_thing")
        end
        error.diagnostic.not_nil!.code.should eq("R008")
        error.error_value.not_nil!.as_robject?.not_nil!.rclass.name.should eq("NameError")
      end

      it "names the type in script terms, not Crystal terms" do
        # The old message interpolated `v.raw.class`, leaking Crystal
        # type names at someone writing Ruby.
        error = expect_raises(RuntimeError) do
          eval("n = 0.0\n-n.to_s")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("R005")
        diag.data["operator"].should eq("-")
        diag.data["type"].should eq("String")
      end

      it "collapses the four uninitialized-constant sites onto one code" do
        error = expect_raises(RuntimeError) { eval("Nope") }
        error.diagnostic.not_nil!.code.should eq("R003")
        error.diagnostic.not_nil!.data["name"].should eq("Nope")
      end

      it "names the method that yielded without a block" do
        error = expect_raises(RuntimeError) do
          eval("def needs_block\n  yield\nend\nneeds_block")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("R007")
        diag.data["method"].should eq("needs_block")
      end

      it "reports U002 for Class.new, with a line but no column" do
        # First VM-raised diagnostic: Frame records a line and no
        # column, so this is the real exercise of the renderer's
        # line-only degradation rather than a synthetic one.
        error = expect_raises(RuntimeError) do
          eval("x = Class.new")
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("U002")
        diag.primary.not_nil!.column.should be_nil
        diag.data["class"].should eq("Class")
      end
    end
  end

  describe "Object model" do
    describe "class creation" do
      it "class becomes a real RubyClass, not a stub" do
        eval("class Foo\nend\nFoo").rclass?.should be_true
      end

      it "class name is set" do
        eval("class Foo\nend\nFoo").as_rclass.name.should eq "Foo"
      end

      it "class defaults to Object as its superclass, not nil" do
        interp, _ = make_interp
        cls = interp.eval("class Foo\nend\nFoo").as_rclass
        cls.superclass.should eq interp.object_class
      end

      it "is not a module" do
        eval("class Foo\nend\nFoo").as_rclass.is_module?.should be_false
      end
    end

    describe "module creation" do
      it "module becomes a real RubyClass tagged as a module" do
        val = eval("module M\nend\nM")
        val.rclass?.should be_true
        val.as_rclass.is_module?.should be_true
      end

      it "module has no superclass" do
        eval("module M\nend\nM").as_rclass.superclass.should be_nil
      end
    end

    # A class/module body previously had NO real local-variable scope
    # at all — a bare `x = 5` inside `class Foo; ...; end` compiled to
    # Op::SetGlobal, the exact same opcode/table a top-level `x = 5`
    # or a `def x` used, so class-body locals silently leaked out as
    # globals and could collide with method names. Fixed by giving
    # class/module bodies (and the top-level program itself) a real
    # CompilerScope — see Compiler#with_nested_scope and
    # Compiler.compile in compiler.cr.
    describe "class/module body local variable scoping" do
      it "a local defined in a module body does not leak outside it" do
        src = <<-RUBY
        module M
          dbl = ->(n) { n + n }
        end
        dbl
        RUBY
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `dbl`/) do
          eval(src)
        end
      end

      it "calling a module-body local like a method raises, matching real Ruby" do
        # Real Ruby: `dbl(3)` where dbl is a local (not a method) is a
        # NameError — locals are never callable with ()-call syntax.
        src = <<-RUBY
        module M
          dbl = ->(n) { n + n }
          dbl(3)
        end
        RUBY
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `dbl`/) do
          eval(src)
        end
      end

      it "a bare receiverless call inside a module body raises unknown symbol error" do
        # Real Ruby: a bare `x` inside `module M`'s body, after `def
        # x`, raises "undefined method" error.
        src = <<-RUBY
        module M
          def x; 42; end
          RESULT = x
        end
        RUBY
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `x`/) do
          eval(src)
        end
      end

      it "a bare receiverless call inside a module body find module's singleton method" do
        # Real Ruby: a bare `x` inside `module M`'s body, after `def
        # self.x`, is available
        src = <<-RUBY
        module M
          def self.x; 42; end
          RESULT = x
        end
        M::RESULT
        RUBY
        eval(src).as_int.should eq 42
      end

      it "a nested module's body cannot see its enclosing module's locals" do
        # The exact motivating example from the 2026-07-15 design
        # conversation: real Ruby raises NameError on `puts tmp_a`
        # inside module B, since a nested module body does NOT close
        # over its enclosing module body's locals (unlike a block,
        # which does).
        src = <<-RUBY
        module A
          tmp_a = 55
          module B
            tmp_b = 66
            tmp_a
          end
        end
        RUBY
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `tmp_a`/) do
          eval(src)
        end
      end

      it "a class body's own local does not collide with the SAME slot an outer local uses" do
        # Regression guard for the slot-numbering half of the fix —
        # without CompilerScope's starting_slot continuing from the
        # outer scope, a fresh class-body scope starting back at slot
        # 0 would silently alias the outer local living at that same
        # Frame.locals index (class/module bodies share their
        # enclosing Frame — see with_nested_scope's own comment).
        src = <<-RUBY
        outer = 1
        module M
          inner = 2
        end
        outer
        RUBY
        eval(src).as_int.should eq 1
      end

      it "class bodies get the same real scoping as module bodies" do
        src = <<-RUBY
        class C
          local = 99
        end
        local
        RUBY
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `local`/) do
          eval(src)
        end
      end
    end

    describe "superclass resolution" do
      it "resolves a defined superclass" do
        val = eval("class Animal\nend\nclass Dog < Animal\nend\nDog")
        sup = val.as_rclass.superclass
        sup.should_not be_nil
        sup.not_nil!.name.should eq "Animal"
      end

      it "raises for an undefined superclass" do
        expect_raises(RuntimeError, /uninitialized constant `Unknown`/) do
          eval("class Dog < Unknown\nend")
        end
      end
    end

    describe "method definitions" do
      it "registers methods on the class method table, not globals" do
        val = eval("class Foo\ndef bar\n1\nend\nend\nFoo")
        cls = val.as_rclass
        cls.methods.size.should eq 1
        cls.methods.first_value.name.should eq "bar"
      end

      it "def outside a class still defines a global function as before" do
        eval("def bar\n42\nend\nbar()").as_int.should eq 42_i64
      end
    end

    describe "self inside a class body" do
      it "self is the class being defined" do
        val = eval("class Foo\n SELF_STR = self.to_s\nend\nFoo::SELF_STR")
        val.as_string.should eq "Foo"
      end

      it "self is restored after the class body, unaffected by the body's last value" do
        # Previously asserted self.null? — only true because top-level
        # self_val defaulted to Value.nil_value before piece B
        # (2026-07-16). Now self at top level is `main` (a real
        # RubyObject of class Object — see Interpreter#main), never
        # nil, matching real Ruby exactly: self after a class body
        # ends, back at top level, is main. Op::GetClass/Op::SetClass
        # correctly save/restore whatever self_val WAS beforehand
        # (main, here), regardless of the class body's own last
        # expression value.
        val = eval("class Foo\n1 + 1\nend\nself.class == Object")
        val.truthy?.should be_true
      end

      it "self is restored correctly across nested class definitions" do
        val = eval(<<-RB)
          class Outer
            class Inner
            end
            OUTER_SELF_STR = self.to_s
          end
          Outer::OUTER_SELF_STR
          RB
        val.as_string.should eq "Outer"
      end
    end

    describe "instantiation (.new)" do
      it "returns a RubyObject of the right class" do
        val = eval("class Foo\nend\nFoo.new")
        val.robject?.should be_true
        val.as_robject.rclass.name.should eq "Foo"
      end

      it "works without an initialize method" do
        eval("class Foo\nend\nFoo.new").robject?.should be_true
      end

      it "runs initialize" do
        val = eval(<<-RB)
          class Foo
            def initialize
              INIT_RAN = true
            end
          end
          Foo.new
          Foo::INIT_RAN
          RB
        val.as_bool.should be_true
      end

      it "returns the new object, not initialize's return value" do
        val = eval(<<-RB)
          class Foo
            def initialize
              999
            end
          end
          Foo.new
          RB
        val.robject?.should be_true
      end

      it "raises when instantiating a module" do
        expect_raises(RuntimeError, /cannot be instantiated/) do
          eval("module M\nend\nM.new")
        end
      end
    end

    describe "instantiation (.new) with keyword arguments" do
      it "a keyword-declaring initialize binds kwargs passed to .new" do
        val = eval(<<-RUBY)
          class Config
            def initialize(retries:, timeout: 10)
              @retries = retries
              @timeout = timeout
            end

            def summary
              "retries=\#{@retries} timeout=\#{@timeout}"
            end
          end
          Config.new(retries: 3, timeout: 5).summary
          RUBY
        val.as_string.should eq "retries=3 timeout=5"
      end

      it "a kwarg's default applies when .new doesn't supply it" do
        val = eval(<<-RUBY)
          class Config
            def initialize(retries:, timeout: 10)
              @retries = retries
              @timeout = timeout
            end

            def summary
              "retries=\#{@retries} timeout=\#{@timeout}"
            end
          end
          Config.new(retries: 1).summary
          RUBY
        val.as_string.should eq "retries=1 timeout=10"
      end

      it "a required kwarg never supplied to .new raises ArgumentError (R011)" do
        expect_raises(RuntimeError) do
          eval(<<-RUBY)
            class Config
              def initialize(retries:)
                @retries = retries
              end
            end
            Config.new
            RUBY
        end
      end

      it "an unknown keyword to .new raises ArgumentError (R012)" do
        expect_raises(RuntimeError) do
          eval(<<-RUBY)
            class Config
              def initialize(retries:)
                @retries = retries
              end
            end
            Config.new(retries: 1, colour: "red")
            RUBY
        end
      end

      it "a keyword arg to .new on a class with no initialize at all still raises, not silently dropped" do
        expect_raises(RuntimeError) do
          eval("class Bare\nend\nBare.new(anything: 1)")
        end
      end

      it "positional and keyword args combine at a constructor" do
        val = eval(<<-RUBY)
          class Point
            def initialize(x, y, label: "point")
              @x = x
              @y = y
              @label = label
            end

            def describe
              "\#{@label}(\#{@x}, \#{@y})"
            end
          end
          Point.new(1, 2, label: "origin").describe
          RUBY
        val.as_string.should eq "origin(1, 2)"
      end
    end

    describe "dup / clone" do
      it "dup copies ivars into a new instance of the same class" do
        val = eval(<<-RUBY)
          class Point
            attr_accessor :x, :y
            def initialize(x, y)
              @x = x
              @y = y
            end
          end
          original = Point.new(1, 2)
          copy = original.dup
          [copy.is_a?(Point), copy.x, copy.y]
          RUBY
        arr = val.as_array
        arr[0].as_bool.should be_true
        arr[1].as_int.should eq 1_i64
        arr[2].as_int.should eq 2_i64
      end

      it "dup's copy is independent of the original" do
        val = eval(<<-RUBY)
          class Point
            attr_accessor :x
            def initialize(x)
              @x = x
            end
          end
          original = Point.new(1)
          copy = original.dup
          copy.x = 99
          [original.x, copy.x]
          RUBY
        arr = val.as_array
        arr[0].as_int.should eq 1_i64
        arr[1].as_int.should eq 99_i64
      end

      it "clone behaves the same as dup" do
        val = eval(<<-RUBY)
          class Point
            attr_accessor :x
            def initialize(x)
              @x = x
            end
          end
          Point.new(3).clone.x
          RUBY
        val.as_int.should eq 3_i64
      end

      it "does not re-run initialize" do
        val = eval(<<-RUBY)
          class Counter
            @@count = 0
            def initialize
              @@count += 1
            end
            def self.count
              @@count
            end
          end
          Counter.new
          before = Counter.count
          Counter.new.dup
          Counter.count - before
          RUBY
        # One real .new (already counted in `before`), plus exactly
        # one more .new — the .dup on THAT instance must not trigger
        # a third initialize call.
        val.as_int.should eq 1_i64
      end

      it "a class-defined initialize_copy runs on dup, original passed as its argument" do
        val = eval(<<-RUBY)
          class Wrapper
            attr_accessor :tag
            def initialize(tag)
              @tag = tag
            end
            def initialize_copy(original)
              @tag = "copy of \#{original.tag}"
            end
          end
          original = Wrapper.new("first")
          copy = original.dup
          [copy.tag, original.tag]
          RUBY
        arr = val.as_array
        arr[0].as_string.should eq "copy of first"
        arr[1].as_string.should eq "first"
      end

      it "dup on a builtin-kind receiver still raises (deliberately out of scope, see SCOPE.md)" do
        expect_raises(RuntimeError) { eval("5.dup") }
      end
    end

    describe "instance method dispatch" do
      it "calls a method defined on the instance's class" do
        val = eval("class Foo\ndef bar\n42\nend\nend\nFoo.new.bar")
        val.as_int.should eq 42_i64
      end

      it "self dispatches back to the receiver for a same-class call" do
        val = eval(<<-RB)
          class Foo
            def outer
              self.inner
            end
            def inner
              7
            end
          end
          Foo.new.outer
          RB
        val.as_int.should eq 7_i64
      end

      it "inherits methods from a superclass" do
        val = eval(<<-RB)
          class Animal
            def speak
              1
            end
          end
          class Dog < Animal
          end
          Dog.new.speak
          RB
        val.as_int.should eq 1_i64
      end

      it "a subclass method overrides the superclass method" do
        val = eval(<<-RB)
          class Animal
            def speak
              1
            end
          end
          class Dog < Animal
            def speak
              2
            end
          end
          Dog.new.speak
          RB
        val.as_int.should eq 2_i64
      end
    end

    describe "receiver-dispatch regression" do
      it "does not treat a plain positional argument as a receiver" do
        val = eval(<<-RB)
          class Foo
          end
          def identity(x)
            x
          end
          identity(Foo.new)
          RB
        val.robject?.should be_true
      end
    end

    describe "instance variables" do
      it "sets and reads an ivar on self via a method" do
        val = eval(<<-RB)
          class Foo
            def set
              @x = 5
            end
            def get
              @x
            end
          end
          f = Foo.new
          f.set
          f.get
          RB
        val.as_int.should eq 5_i64
      end

      it "ivars are set via initialize" do
        val = eval(<<-RB)
          class Foo
            def initialize(v)
              @x = v
            end
            def get
              @x
            end
          end
          Foo.new(9).get
          RB
        val.as_int.should eq 9_i64
      end

      it "ivars are isolated per instance" do
        val = eval(<<-RB)
          class Foo
            def set(v)
              @x = v
            end
            def get
              @x
            end
          end
          a = Foo.new
          b = Foo.new
          a.set(1)
          b.set(2)
          a.get
          RB
        val.as_int.should eq 1_i64
      end

      it "unset ivar reads as nil" do
        val = eval(<<-RB)
          class Foo
            def get
              @unset
            end
          end
          Foo.new.get
          RB
        val.null?.should be_true
      end

      it "ivar outside an object silently reads as nil" do
        eval("@x").null?.should be_true
      end
    end

    describe "class variables" do
      it "sets and reads a cvar from an instance method" do
        val = eval(<<-RB)
          class Foo
            def set
              @@count = 1
            end
            def get
              @@count
            end
          end
          f = Foo.new
          f.set
          f.get
          RB
        val.as_int.should eq 1_i64
      end

      it "cvars are shared across instances" do
        val = eval(<<-RB)
          class Foo
            def bump
              @@count = (@@count || 0) + 1
            end
            def get
              @@count
            end
          end
          a = Foo.new
          b = Foo.new
          a.bump
          b.bump
          a.get
          RB
        val.as_int.should eq 2_i64
      end

      it "a subclass reads the superclass's cvar" do
        val = eval(<<-RB)
          class Animal
            @@kind = 1
            def kind
              @@kind
            end
          end
          class Dog < Animal
          end
          Dog.new.kind
          RB
        val.as_int.should eq 1_i64
      end

      it "a subclass write updates the shared superclass cvar" do
        val = eval(<<-RB)
          class Animal
            @@kind = 1
            def get
              @@kind
            end
          end
          class Dog < Animal
            def set
              @@kind = 2
            end
          end
          d = Dog.new
          d.set
          Animal.new.get
          RB
        val.as_int.should eq 2_i64
      end

      it "@@x at top level is legal, matching real Ruby — defines a cvar on Object " \
         "(self is main, an instance of Object)" do
        # Previously asserted this raises — that was itself the bug,
        # an artifact of top-level self_val defaulting to nil_value
        # before piece B (2026-07-16). Real Ruby: `@@x = 1` at the
        # top level of a script IS legal, and defines a class
        # variable on Object. Adjutant now matches this exactly,
        # since self at top level is `main` (Interpreter#main, a real
        # RubyObject of class Object) — cvar_class's
        # `f.self_val.as_robject?.rclass` branch correctly resolves
        # to Object, same as it would for any other RubyObject
        # instance. cvar_class's raise is still real code (see
        # vm.cr), just no longer reachable via a normal eval call now
        # that self_val is never genuinely absent for a VM built with
        # a real Interpreter — only a VM constructed with no
        # Interpreter at all (not exercised by any spec) still hits
        # the nil_value default that raise guards against.
        eval("@@x = 1\n@@x").as_int.should eq 1
      end
    end

    describe "constants" do
      it "a top-level constant is globally visible" do
        eval("MYCONST = 5\nMYCONST").as_int.should eq 5_i64
      end

      it "a constant defined inside a class is scoped to that class" do
        val = eval(<<-RB)
          class A
            MYCONST = 3
          end
          A::MYCONST
          RB
        val.as_int.should eq 3_i64
      end

      it "a class-scoped constant does not leak to the top level" do
        expect_raises(RuntimeError, /uninitialized constant/) do
          eval("class A\nMYCONST = 3\nend\nMYCONST")
        end
      end

      it "resolves a doubly-nested constant via an explicit path" do
        val = eval(<<-RB)
          class A
            class B
              MYCONST = 7
            end
          end
          A::B::MYCONST
          RB
        val.as_int.should eq 7_i64
      end

      it "a method sees the constant lexically nested at its own def site, not an outer shadowed one" do
        val = eval(<<-RB)
          class A
            MYCONST = 3
            class B
              MYCONST = 4
              def x
                MYCONST
              end
            end
          end
          A::B.new.x
          RB
        val.as_int.should eq 4_i64
      end

      it "a method falls back to an outer lexical constant when its own scope doesn't define one" do
        val = eval(<<-RB)
          class A
            MYCONST = 3
            class B
              def x
                MYCONST
              end
            end
          end
          A::B.new.x
          RB
        val.as_int.should eq 3_i64
      end

      it "constant lookup is lexical, not based on the superclass chain" do
        expect_raises(RuntimeError, /uninitialized constant/) do
          eval(<<-RB)
            class Animal
              MYCONST = 1
            end
            class Dog < Animal
              def get
                MYCONST
              end
            end
            Dog.new.get
            RB
        end
      end

      it "raises for a totally undefined constant" do
        expect_raises(RuntimeError, /uninitialized constant/) do
          eval("NOPE")
        end
      end

      it "leading :: bypasses lexical scope and goes straight to the top level" do
        val = eval(<<-RB)
          module A
          end
          class B
            class A
            end
            def x
              ::A
            end
          end
          B.new.x
          RB
        val.rclass?.should be_true
        val.as_rclass.name.should eq "A"
        val.as_rclass.is_module?.should be_true
      end

      it "bare reference inside the nested scope finds the shadowing inner constant" do
        val = eval(<<-RB)
          module A
          end
          class B
            class A
            end
            def y
              A
            end
          end
          B.new.y
          RB
        val.rclass?.should be_true
        val.as_rclass.is_module?.should be_false
      end

      it "raises for an undefined leading :: constant" do
        expect_raises(RuntimeError, /uninitialized constant `NOPE`/) do
          eval("::NOPE")
        end
      end

      it "chains a leading :: path" do
        val = eval(<<-RB)
          module A
            module B
              X = 1
            end
          end
          ::A::B::X
          RB
        val.as_int.should eq 1_i64
      end

      it "#to_s returns qualified name" do
        val = eval(<<-RB)
          module A
            class B
            end
          end
          A::B.new.class.to_s
        RB
        val.as_string.should eq "A::B"
      end
    end

    describe "a Class/Module value's own #to_s/#inspect" do
      # `MyClass.to_s` already worked before this fix, via a
      # universal exec_builtin fallback case (vm.cr) — the explicit-
      # receiver rclass dispatch branch only checks SINGLETON method
      # tables, finds nothing (no type registers a native singleton
      # `to_s`/`inspect`), and falls through to that catch-all.
      # `MyClass.inspect` had NO equivalent fallback at all before
      # this — a flat `NoMethodError` (R008), not just a wrong
      # string. Every case below documents that specific fix.

      it "MyClass.to_s returns the qualified name, unaffected by this change" do
        eval("class Foo\nend\nFoo.to_s").as_string.should eq "Foo"
      end

      it "MyClass.inspect now works at all — previously raised NoMethodError" do
        eval("class Foo\nend\nFoo.inspect").as_string.should eq "Foo"
      end

      it "to_s and inspect agree, matching real Ruby's default (no override) case" do
        result = eval("class Foo\nend\n[Foo.to_s, Foo.inspect]")
        strs = result.as_array.map(&.as_string)
        strs[0].should eq strs[1]
      end

      it "a nested class's inspect returns its qualified name, same as to_s" do
        val = eval(<<-RB)
          module A
            class B
            end
          end
          A::B.inspect
        RB
        val.as_string.should eq "A::B"
      end

      it "a Module value's inspect works the same way as a Class value's" do
        eval("module M\nend\nM.inspect").as_string.should eq "M"
      end
    end

    describe "a Class's own def self.to_s/def self.inspect override, respected implicitly (not just via an explicit call)" do
      # Fixed 2026-08-18 — the "Known gap" SCOPE.md flagged when the
      # rest of the to_s/inspect overridability work shipped:
      # render_to_s/render_inspect (vm.cr) used to keep RubyClass
      # values on the Crystal-level fast path unconditionally, never
      # checking for a script-defined override at all. Now checks
      # first (rclass_override?) and only dispatches when one
      # actually exists — a class with NO override still uses the
      # exact same default rendering as before, unaffected.

      it "string interpolation respects a class's own def self.to_s override" do
        eval(<<-RB).should eq Value.string("value: custom!")
          class Foo
            def self.to_s
              "custom!"
            end
          end
          "value: \#{Foo}"
        RB
      end

      it "a class with NO override still interpolates as its qualified name, unaffected" do
        eval(<<-RB).should eq Value.string("value: Foo")
          class Foo
          end
          "value: \#{Foo}"
        RB
      end

      it "puts respects a class's own def self.to_s override" do
        interp, ef = make_interp
        interp.eval(<<-RB)
          class Foo
            def self.to_s
              "custom!"
            end
          end
          puts(Foo)
        RB
        ef.stdout.should eq "custom!\n"
      end

      it "p respects a class's own def self.inspect override, independent of any to_s override" do
        interp, ef = make_interp
        interp.eval(<<-RB)
          class Foo
            def self.to_s
              "custom to_s"
            end

            def self.inspect
              "custom inspect"
            end
          end
          p(Foo)
        RB
        ef.stdout.should eq "custom inspect\n"
      end

      it "a class with an inspect override respond_to?(:inspect) is true — was already true before this fix, since a real override is a real singleton method" do
        result = eval(<<-RB)
          class Foo
            def self.inspect
              "x"
            end
          end
          Foo.respond_to?(:inspect)
        RB
        result.truthy?.should be_true
      end

      it "a class with NO override still fails respond_to?(:to_s) — the documented, accepted, narrower residual gap" do
        result = eval("class Foo\nend\nFoo.respond_to?(:to_s)")
        result.falsy?.should be_true
      end

      it "an exception (deliberately raised inside the override) propagates normally, is NOT silently swallowed into a fallback rendering" do
        result = eval(<<-RB)
          class Boom
            def self.to_s
              raise "boom"
            end
          end
          begin
            "\#{Boom}"
          rescue RuntimeError
            "caught"
          end
        RB
        result.as_string.should eq "caught"
      end
    end
  end
end
