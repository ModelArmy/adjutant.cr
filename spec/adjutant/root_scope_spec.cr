require "../spec_helper"

module Adjutant
  # Piece B of the 2026-07-15/16 scoping work: top-level `self` is now
  # a real RubyObject — `main`, an instance of Object (Interpreter#main)
  # — matching real Ruby exactly rather than a simplification of it. A
  # top-level `def` becomes a genuine method of Object (Op::DefMethod
  # no longer special-cases "am I at top level"); a native function
  # registered via `define_native` registers into Object's own
  # native_methods table (Interpreter#define_native); dispatch_call
  # gained an implicit-self step so a bare/receiverless call correctly
  # tries `self`'s own methods first, matching real Ruby's actual
  # method resolution — which is what makes top-level defs/natives
  # reachable again now that @globals no longer holds them at all.
  #
  # This directly fixes the original motivating bug from this whole
  # design thread: a top-level `def dbl` and a top-level local
  # `dbl = ->(n) { ... }` used to share ONE @globals slot (a real
  # namespace collision) — they're now genuinely separate bindings
  # (Object#methods vs. a CompilerScope-allocated local), matching
  # real Ruby precisely.
  describe "root scope (main/Object)" do
    describe "self at top level" do
      it "is a real RubyObject, not a RubyClass or nil" do
        eval("self.class == Object").truthy?.should be_true
      end

      it "is not an Array/Integer/anything else" do
        eval("self.is_a?(Array)").falsy?.should be_true
      end
    end

    describe "top-level def" do
      it "becomes callable via a later bare reference (no parens)" do
        eval("def greet; \"hi\"; end\ngreet").as_string.should eq "hi"
      end

      it "becomes callable via a later reference with parens" do
        eval("def greet; \"hi\"; end\ngreet()").as_string.should eq "hi"
      end

      it "is callable on ANY object, since it's a real (private) Object method" do
        # The whole point of matching real Ruby here rather than a
        # simplification: a top-level def isn't confined to some
        # top-level-only table, it's a genuine method on Object,
        # reachable from any object anywhere — same as real Ruby's
        # own top-level-def-becomes-private-Object-method behavior.
        src = <<-RUBY
        def greet; "hi"; end
        class Foo
          def call_greet
            greet
          end
        end
        Foo.new.call_greet
        RUBY
        eval(src).as_string.should eq "hi"
      end
    end

    describe "the original dbl/def dbl collision" do
      it "dbl(3) with explicit parens always resolves the METHOD, never the local's lambda" do
        # The original bug this whole design thread started from: a
        # top-level def and a top-level local sharing one @globals
        # slot meant dbl(3) could accidentally invoke the LOCAL's
        # lambda instead of the method. Now genuinely separate
        # bindings (Object#methods vs. a CompilerScope local) —
        # dbl(3) (explicit parens — always parses as a Call, see
        # parser_spec.cr) reliably means the method.
        src = <<-RUBY
        dbl = ->(n) { n + n }
        def dbl(n); n * 10; end
        dbl(3)
        RUBY
        eval(src).as_int.should eq 30
      end

      it "a bare dbl (no parens) reads back the local, not the method — real Ruby's actual rule " \
         "once a local of that name is in scope" do
        # No .class/.proc?/.call script-level introspection used here
        # (all still gaps for a bare lambda Value — see the
        # still-pending Proc-wrapping piece) — proven instead by the
        # fact this doesn't raise/doesn't silently call the method:
        # a bare identifier that resolves to a local is Op::GetLocal,
        # unconditionally, regardless of a same-named def existing
        # (see compile_identifier — local resolution never even
        # LOOKS at whether a method of that name exists).
        src = <<-RUBY
        dbl = ->(n) { n + n }
        def dbl(n); n * 10; end
        dbl
        RUBY
        eval(src).proc?.should be_true
      end
    end

    describe "native functions (define_native)" do
      it "is callable via implicit self, same as a top-level def" do
        interp, _ = make_interp
        interp.define_native("double") { |args| Value.int(args.first.as_int * 2) }
        interp.eval("double(21)").as_int.should eq 42
      end

      it "is callable on any object, matching real Ruby's Kernel-methods-are-Object-methods model" do
        interp, _ = make_interp
        interp.define_native("shout") { |args| Value.string(args.first.as_string.upcase) }
        src = <<-RUBY
        class Foo
          def call_shout
            shout("hi")
          end
        end
        Foo.new.call_shout
        RUBY
        interp.eval(src).as_string.should eq "HI"
      end

      it "IS reachable via an explicit receiver too, since it's inherited from Object — " \
         "Adjutant has no private/public method-visibility model (a real, separate gap " \
         "from real Ruby, not something piece B attempts to close)" do
        # Real Ruby: Kernel/Object methods are PRIVATE, so an explicit
        # receiver call (`obj.puts`, even `self.puts`) raises
        # NoMethodError — Adjutant has no visibility modifiers at all
        # (no `private`/`public`/`protected` anywhere in this
        # codebase), so a native function registered via define_native
        # is a perfectly ordinary INHERITED method as far as Adjutant
        # is concerned: Foo < Object, so Foo.new.double(21) correctly
        # finds it via the normal find_native_method superclass walk,
        # same as any other inherited method would. Implementing
        # method visibility is a real, separate feature, out of scope
        # here.
        #
        # Note args.first is the RECEIVER here (Foo.new), matching the
        # established convention every native method in this codebase
        # uses for a receiver-based call (e.g. Integer#to_s reads
        # args.first.as_int as ITS receiver — see builtins/integer.cr)
        # — the real argument (21) is at args[1].
        interp, _ = make_interp
        interp.define_native("double") { |args| Value.int(args[1].as_int * 2) }
        src = <<-RUBY
        class Foo; end
        Foo.new.double(21)
        RUBY
        interp.eval(src).as_int.should eq 42
      end

      it "a script-defined method of the same name shadows a native function, matching real Ruby" do
        interp, _ = make_interp
        interp.define_native("greet") { |_| Value.string("native") }
        interp.eval("def greet; \"script\"; end\ngreet").as_string.should eq "script"
      end

      it "is callable bare from inside a module body — regression guard" do
        # The exact regression reported after piece B landed: self
        # inside `module M; ...; end`'s body is M itself (a
        # RubyClass), and a module has no superclass of its OWN to
        # walk (only classes do) — so a native/Kernel-style call
        # (assert_not_nil, puts, ...) needed self.rclass's (Module's)
        # OWN chain up to Object, which was broken at its very first
        # link (Module.superclass was nil — see
        # core_class_hierarchy_spec.cr's own coverage of the fix).
        interp, _ = make_interp
        interp.define_native("assert_not_nil") { |args| Value.bool(!args.first.null?) }
        src = <<-RUBY
        module M
          def self.x; end

          RESULT = assert_not_nil(x)
        end
        M::RESULT
        RUBY
        # x is a script-defined method returning nil (implicit last
        # value of an empty body) — assert_not_nil(nil) is false;
        # what matters here is that the CALL resolves at all, not the
        # specific true/false result.
        interp.eval(src).falsy?.should be_true
      end

      it "is callable bare from inside a class body too" do
        interp, _ = make_interp
        interp.define_native("shout") { |args| Value.string(args.first.as_string.upcase) }
        src = <<-RUBY
        class Foo
          RESULT = shout("hi")
        end
        Foo::RESULT
        RUBY
        interp.eval(src).as_string.should eq "HI"
      end

      it "a class's own future INSTANCE methods are not reachable bare inside its own body — " \
         "a real, deliberate distinction (instance methods mean 'available on an instance', " \
         "not 'available on the class object itself')" do
        src = <<-RUBY
        class Foo
          def bar; "instance method"; end
          bar
        end
        RUBY
        expect_raises(Adjutant::RuntimeError, /undefined method or variable: bar/) do
          eval(src)
        end
      end
    end

    describe "def self.foo at top level" do
      it "is legal and defines a class method of Object — matching Op::DefSingleton's " \
         "documented approximation, not a true per-instance singleton method" do
        # Real Ruby: `def self.foo` at top level, where self is
        # `main` (an OBJECT, not a class), defines a true per-instance
        # singleton method on that specific object — later callable
        # bare (implicit self), since main is still self. Adjutant has
        # no per-instance singleton-method table on RubyObject at all
        # (only RubyClass-level ones) — see Op::DefSingleton's own
        # "NOTE — approximation, not a full fix" comment in vm.cr —
        # so this defines a class method of Object instead (correctly
        # callable as Object.greet, an explicit-receiver call), not a
        # method reachable via a later BARE greet. A real, separate,
        # already-flagged gap from full Ruby fidelity; a true
        # per-instance singleton-method table would be its own piece
        # of work, not folded into piece B.
        eval("def self.greet; \"hi\"; end\nObject.greet").as_string.should eq "hi"
      end
    end

    describe "class/module-body def still targets the right class, unaffected by this change" do
      it "def inside a class body still defines an instance method of that class" do
        src = <<-RUBY
        class Foo
          def greet
            "hi from Foo"
          end
        end
        Foo.new.greet
        RUBY
        eval(src).as_string.should eq "hi from Foo"
      end

      it "def self.foo inside a class body still defines a singleton method" do
        src = <<-RUBY
        class Foo
          def self.greet
            "class method"
          end
        end
        Foo.greet
        RUBY
        eval(src).as_string.should eq "class method"
      end
    end

    describe "constants and classes still live in @globals (unaffected by this change)" do
      it "a top-level class is still reachable by bare name, matching prior behavior" do
        eval("class Foo; end\nFoo.class.to_s").as_string.should eq "Class"
      end
    end
  end
end
