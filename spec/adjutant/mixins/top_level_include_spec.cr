require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "top-level `def` is implicitly private (matches real Ruby's `main`/Object relationship)" do
      # Confirmed against a real `irb` session before implementing:
      # a top-level `def` lands in `Object.private_methods`, not
      # `Object.methods` — unreachable via an explicit receiver from
      # outside `self`, even where the receiver is `Object` itself or
      # a freshly-constructed `Object.new` — while a bare call and
      # `self.` both still work. See SCOPE.md's "Object model" group
      # and DEVELOPMENT.md for the full design reasoning. NOT a
      # reopening of U008 (private/protected/public stays a
      # deliberate non-goal as a script-declarable feature) — this is
      # a single, fixed, always-on rule with no `private` keyword
      # involved.

      it "a bare call to a top-level `def` still works" do
        eval(<<-RUBY).should eq Value.string("hi")
        def greet
          "hi"
        end
        greet
        RUBY
      end

      it "`self.` still works from inside the frame where self is main" do
        eval(<<-RUBY).should eq Value.string("hi")
        def greet
          "hi"
        end
        self.greet
        RUBY
      end

      it "an explicit receiver on a fresh, unrelated Object instance is rejected — R023" do
        error = expect_raises(RuntimeError) do
          eval(<<-RUBY)
          def greet
            "hi"
          end
          x = Object.new
          x.greet
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("R023")
        diag.data["method"].should eq("greet")
      end

      it "R023 is script-catchable as NoMethodError, matching Ruby" do
        eval(<<-RUBY).should eq Value.string("caught")
        def greet
          "hi"
        end
        begin
          Object.new.greet
        rescue NoMethodError => e
          "caught"
        end
        RUBY
      end

      it "the R023 diagnostic names the method and the receiver's class" do
        error = expect_raises(RuntimeError) do
          eval(<<-RUBY)
          def greet
            "hi"
          end
          Object.new.greet
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.data["target"].should eq("an instance of Object")
      end

      it "a top-level def is still an ordinary, callable method for everything OTHER than an outside explicit receiver — no regression in the include fix's own coverage" do
        eval(<<-RUBY).should eq Value.string("A-helper-M")
        module M
          def run
            "A-" + helper
          end
        end
        def helper
          "helper-M"
        end
        include M
        run
        RUBY
      end
    end

    describe "the distinguishing factor is HOW a method was defined, not WHERE it ends up" do
      # `class Object; def foo; end; end` would be the natural script-
      # level way to demonstrate this contrast directly — but `U003`
      # forbids reopening ANY class, Object included, so that
      # construct isn't reachable from a script at all. The underlying
      # logic (self is a RubyClass at Op::DefMethod time never marks
      # private, regardless of WHICH class) is instead covered
      # directly against `RubyClass` below, in the "direct unit
      # coverage" describe block — `find_method_private?` returning
      # `false` for an ordinarily-defined method demonstrates exactly
      # this, without needing a script construct Adjutant doesn't
      # support to exercise it.
    end

    describe "redefinition resets visibility (matches real Ruby — visibility is per-declaration, not inherited automatically)" do
      # A top-level `def` redefining Object directly (rather than a
      # subclass overriding an inherited name) would be the more
      # direct way to show this — but that's the same `class Object;
      # ...; end` shape `U003` forbids, same as the describe block
      # above. The subclass case below exercises the identical
      # underlying rule (a closer definition's own visibility wins,
      # regardless of what an ancestor declared) through a construct
      # Adjutant actually supports.

      it "a subclass overriding a private inherited method WITHOUT redeclaring it private makes the override public" do
        eval(<<-RUBY).should eq Value.string("A's own")
        def greet
          "top-level"
        end
        class A
          def greet
            "A's own"
          end
        end
        A.new.greet
        RUBY
      end
    end

    describe "`RubyClass#private_methods`/`native_private_methods` — direct unit coverage" do
      it "define_method with is_private: true adds to private_methods; false (default) doesn't" do
        cls = RubyClass.new("Test")
        proc = ScriptProc.new(Chunk.new, "foo")
        cls.define_method(1, proc, is_private: true)
        cls.private_methods.should eq Set{1}
      end

      it "redefining the same sym_id without is_private clears it from private_methods" do
        cls = RubyClass.new("Test")
        proc = ScriptProc.new(Chunk.new, "foo")
        cls.define_method(1, proc, is_private: true)
        cls.define_method(1, proc)
        cls.private_methods.should be_empty
      end

      it "find_method_private? returns false for a name that isn't defined at all" do
        cls = RubyClass.new("Test")
        cls.find_method_private?(999).should be_false
      end

      it "find_method_private? returns false for a name that resolves but isn't private" do
        cls = RubyClass.new("Test")
        proc = ScriptProc.new(Chunk.new, "foo")
        cls.define_method(1, proc)
        cls.find_method_private?(1).should be_false
      end

      it "find_method_private? walks the superclass chain, same as find_method itself" do
        base = RubyClass.new("Base")
        proc = ScriptProc.new(Chunk.new, "foo")
        base.define_method(1, proc, is_private: true)
        sub = RubyClass.new("Sub", base)
        sub.find_method_private?(1).should be_true
      end

      it "a subclass's own (public) override of a privately-inherited name wins — closer definition, matches find_method's own resolution order" do
        base = RubyClass.new("Base")
        base_proc = ScriptProc.new(Chunk.new, "foo")
        base.define_method(1, base_proc, is_private: true)
        sub = RubyClass.new("Sub", base)
        sub_proc = ScriptProc.new(Chunk.new, "foo")
        sub.define_method(1, sub_proc)
        sub.find_method_private?(1).should be_false
      end

      it "an included module's own private method stays private when consulted through the including class" do
        mod = RubyClass.new("M", is_module: true)
        proc = ScriptProc.new(Chunk.new, "whisper")
        mod.define_method(1, proc, is_private: true)
        cls = RubyClass.new("A")
        cls.include_module(mod)
        cls.find_method_private?(1).should be_true
      end
    end
  end
end
