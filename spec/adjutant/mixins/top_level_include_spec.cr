require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "bare `include` at the top level (main)" do
      # Confirmed against a real `irb` session before implementing:
      # top-level `include M` mutates `Object`'s own ancestor chain
      # directly — the mixed-in method is an ordinary PUBLIC instance
      # method, reachable from ANY `Object` instance via explicit
      # receiver, not just bare calls at the top level. See
      # SCOPE.md's "Object model" group and UNSUPPORTED.md's U018
      # entry for the full design reasoning.

      it "a bare call to the included module's method works after `include` at the top level" do
        eval(<<-RUBY).should eq Value.string("hi from M")
        module M
          def greet
            "hi from M"
          end
        end
        include M
        greet
        RUBY
      end

      it "the included method is also callable via `self.` at the top level" do
        eval(<<-RUBY).should eq Value.string("hi from M")
        module M
          def greet
            "hi from M"
          end
        end
        include M
        self.greet
        RUBY
      end

      it "the included method becomes callable on OTHER, unrelated Object instances too — matching real Ruby, not scoped to main alone" do
        eval(<<-RUBY).should eq Value.string("xy")
        module M
          def greet(s)
            s
          end
        end
        include M
        x = Object.new
        y = Object.new
        x.greet("x") + y.greet("y")
        RUBY
      end

      it "top-level `include` adds the module to Object's own included_modules" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M
        end
        include M
        RUBY
        object_class = interp.get_global("Object").as_rclass
        m = interp.get_global("M").as_rclass
        object_class.included_modules.should eq [m]
      end

      it "multiple top-level includes resolve in real MRO order — the LAST one included wins" do
        eval(<<-RUBY).should eq Value.string("from M2")
        module M1
          def greet
            "from M1"
          end
        end
        module M2
          def greet
            "from M2"
          end
        end
        include M1
        include M2
        greet
        RUBY
      end

      it "a top-level `def` still wins over an included module's same-named method — implicit-self resolution order is unaffected" do
        eval(<<-RUBY).should eq Value.string("top-level def")
        module M
          def greet
            "from M"
          end
        end
        include M
        def greet
          "top-level def"
        end
        greet
        RUBY
      end

      it "an included module's method still runs with self bound to main, not the module" do
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

      it "top-level `include` returns self (main), matching real Ruby's Module#include" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        module M
        end
        include M
        RUBY
        result.as_robject.rclass.should eq interp.main.rclass
      end

      it "a script with no top-level `include` at all leaves Object's included_modules untouched" do
        interp, _ = make_interp
        interp.eval("1 + 1")
        object_class = interp.get_global("Object").as_rclass
        object_class.included_modules.should be_empty
      end

      it "bare `include M` written inside an ORDINARY instance method body (self is not main) is NOT resolved by this new path — still excluded (U018), same as before this change" do
        error = expect_raises(RuntimeError) do
          eval(<<-RUBY)
          module M
          end
          class A
            def try_include
              include M
            end
          end
          A.new.try_include
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("U018")
      end
    end

    describe "bare `extend` at the top level (main) — deliberately still excluded" do
      # Confirmed against a real `irb` session: top-level `extend`
      # writes to a genuine per-object singleton class on main alone
      # (Object's ancestors unchanged, sibling instances unaffected,
      # Object.foo unaffected) — RubyObject has no storage for that
      # today. Left excluded on purpose rather than approximated with
      # `include`'s semantics; see vm.cr's own comment on this
      # decision and SCOPE.md for the follow-up item.

      it "`extend M` at the top level still raises U018, unaffected by the include fix" do
        error = expect_raises(RuntimeError) do
          eval(<<-RUBY)
          module M
            def greet
              "hi"
            end
          end
          extend M
          greet
          RUBY
        end
        diag = error.diagnostic.not_nil!
        diag.code.should eq("U018")
        diag.data["construct"].should eq("extend")
      end
    end

    describe "top-level `include` inside a class/module body is completely unaffected (regression check)" do
      # The new dispatch branch is gated on self.same?(interp.main) —
      # this confirms a class/module body's own, already-working
      # `include` path (self is a RubyClass there, a different branch
      # entirely) never even reaches the new check.

      it "`include` still works normally inside a class body" do
        eval(<<-RUBY).should eq Value.string("hi from M")
        module M
          def greet
            "hi from M"
          end
        end
        class A
          include M
        end
        A.new.greet
        RUBY
      end
    end
  end
end
