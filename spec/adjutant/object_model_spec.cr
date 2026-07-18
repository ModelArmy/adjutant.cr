require "../spec_helper"

module Adjutant
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: dbl/) do
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: dbl/) do
          eval(src)
        end
      end

      it "a bare receiverless call inside a module body correctly checks self's own methods" do
        # Real Ruby: a bare `x` inside `module M`'s body, after `def
        # x`, implicitly calls M's own method x (self is receiver by
        # default inside a class/module/method body). Previously
        # documented here as a gap (dispatch_call had no implicit-self
        # step for the receiverless path) — fixed as part of the
        # 2026-07-16 root-scope work (piece B), where implicit self
        # became load-bearing: it's the SAME mechanism that makes a
        # bare top-level `def greet` reachable via a later bare
        # `greet` (top-level self is `main`, a RubyObject of class
        # Object), so a module/class body's own `def x` reachable via
        # a later bare `x` came along for free with the same fix.
        #
        # Can't just check eval(src) directly here — a module/class
        # DEFINITION STATEMENT always evaluates to nil regardless of
        # its body's last expression (see compile_module's own
        # `emit_nil` — a real, pre-existing, separate simplification,
        # unrelated to piece B), so `x`'s own return value (42) is
        # discarded by the module statement itself before reaching
        # `eval`'s result. Capture it into a constant instead, and
        # read that back afterward, to actually observe it.
        src = <<-RUBY
        module M
          def x; 42; end
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: tmp_a/) do
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
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: local/) do
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
        expect_raises(RuntimeError, /uninitialized constant Unknown/) do
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
        expect_raises(RuntimeError, /can't instantiate module/) do
          eval("module M\nend\nM.new")
        end
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
        expect_raises(RuntimeError, /uninitialized constant NOPE/) do
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
  end
end
