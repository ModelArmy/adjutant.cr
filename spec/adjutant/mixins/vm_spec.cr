require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "include (Step 2 — registration only, no method resolution yet)" do
      # `include` now registers the module into the including class's
      # own `included_modules` — actual method lookup honoring it
      # (RubyClass#find_method/find_native_method walking
      # included_modules) is Step 3, not built yet. These specs
      # confirm registration itself: the right module ends up in the
      # right place, in the right order, and calling `include`
      # doesn't blow up — NOT that an included method is callable yet
      # (that would fail right now, on purpose, until Step 3 lands).

      it "include adds the module to the including class's included_modules" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M
        end
        class A
          include M
        end
        RUBY
        a = interp.get_global("A").as_rclass
        m = interp.get_global("M").as_rclass
        a.included_modules.should eq [m]
      end

      it "include works inside a module body too, not just a class body" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M
        end
        module N
          include M
        end
        RUBY
        n = interp.get_global("N").as_rclass
        m = interp.get_global("M").as_rclass
        n.included_modules.should eq [m]
      end

      it "multiple includes are stored in SOURCE order (insertion order — MRO reversal is Step 3's concern, not storage's)" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M1
        end
        module M2
        end
        class A
          include M1
          include M2
        end
        RUBY
        a = interp.get_global("A").as_rclass
        m1 = interp.get_global("M1").as_rclass
        m2 = interp.get_global("M2").as_rclass
        a.included_modules.should eq [m1, m2]
      end

      it "`include` returns self (the including class), matching real Ruby's Module#include" do
        # A `class ... end` statement always evaluates to nil itself
        # (compile_class discards the body's own last value
        # unconditionally) — so include's return value has to be
        # captured from INSIDE the class, not read off eval's own
        # top-level result.
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        module M
        end
        class A
          def self.try_include
            include M
          end
        end
        A.try_include
        RUBY
        result.as_rclass.name.should eq "A"
      end

      it "a class with no include at all has an empty included_modules, unaffected" do
        interp, _ = make_interp
        interp.eval("class A\nend")
        a = interp.get_global("A").as_rclass
        a.included_modules.should be_empty
      end

      it "including the SAME module twice currently appends it twice — real Ruby de-duplicates (already-in-ancestor-chain check), this doesn't yet" do
        # Flagging honestly rather than claiming parity: harmless for
        # correctness on its own (the same module answering the same
        # way twice during resolution isn't WRONG, just redundant
        # work), but worth a decision in Step 3 when real chain-
        # walking is built — either add a de-dup check here in
        # include_module itself, or leave it and accept the minor
        # inefficiency. Not decided yet.
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M
        end
        class A
          include M
          include M
        end
        RUBY
        a = interp.get_global("A").as_rclass
        m = interp.get_global("M").as_rclass
        a.included_modules.should eq [m, m]
      end
    end

    describe "include (Step 3 — actual method resolution)" do
      # find_method/find_native_method (RubyClass) now walk
      # included_modules — this is the step that makes `include`
      # actually DO something. VM#dispatch_call and VM#dispatch_super
      # both call these same two methods rather than having their own
      # copies, so module-aware resolution reached both automatically.
      # RiskWalker turned out to need its OWN separate fix too — see
      # the "RiskWalker resolves a call reached through an included
      # module" spec below for why (it never executes anything, so
      # `include`'s runtime effect needed static recognition of its
      # own) — corrected here rather than left as an inaccurate
      # "automatic" claim. See DEVELOPMENT.md.

      it "a class including a module can call the module's instance method" do
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

      it "the class's OWN method wins over an included module's same-named method" do
        eval(<<-RUBY).should eq Value.string("A's own")
        module M
          def greet
            "from M"
          end
        end
        class A
          include M
          def greet
            "A's own"
          end
        end
        A.new.greet
        RUBY
      end

      it "with multiple includes, the LAST one included wins (real Ruby MRO — closest to the class)" do
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
        class A
          include M1
          include M2
        end
        A.new.greet
        RUBY
      end

      it "an included module's method still runs with self bound to the ACTUAL instance, not the module" do
        eval(<<-RUBY).should eq Value.int(42_i64)
        module M
          def show
            @value
          end
        end
        class A
          include M
          def initialize
            @value = 42
          end
        end
        A.new.show
        RUBY
      end

      it "an included module's method can call another of the CLASS's own methods (self stays the real instance throughout)" do
        eval(<<-RUBY).should eq Value.string("A-helper-M")
        module M
          def run
            "A-" + helper
          end
        end
        class A
          include M
          def helper
            "helper-M"
          end
        end
        A.new.run
        RUBY
      end

      it "a module included in a module (nested inclusion) is reachable transitively" do
        eval(<<-RUBY).should eq Value.string("deep")
        module Inner
          def deep_method
            "deep"
          end
        end
        module Outer
          include Inner
        end
        class A
          include Outer
        end
        A.new.deep_method
        RUBY
      end

      it "super still correctly reaches the superclass when the included module doesn't define the method at all" do
        # This test's ORIGINAL version (pre Step 4) asserted "Base-A"
        # here with M ALSO defining greet — that was actually
        # asserting the BUG Step 4 fixed: M genuinely sits in A's
        # ancestor chain, so super SHOULD reach M's greet before
        # Base's (see the "include + super" describe block below for
        # that exact scenario, now correctly covered). Rewritten so
        # this test asserts what its title actually says: with NO
        # naming conflict, super correctly passes straight through M
        # (nothing found there) and reaches Base, unaffected by M's
        # mere presence in the chain.
        eval(<<-RUBY).should eq Value.string("Base-A")
        module M
          def unrelated_method
            "unrelated"
          end
        end
        class Base
          def greet
            "Base"
          end
        end
        class A < Base
          include M
          def greet
            super + "-A"
          end
        end
        A.new.greet
        RUBY
      end

      it "RiskWalker resolves a call reached through an included module" do
        # This turned out to need its own fix, not "automatic" the
        # way super/dispatch_call's module-awareness was —
        # find_method/find_native_method being shared was necessary
        # but not sufficient. RiskWalker never EXECUTES anything (a
        # purely static walk); `include M` only mutates
        # `A.included_modules` when the real native `include` method
        # actually RUNS, which never happens here. Without
        # RiskWalker's own static recognition of `include`
        # (walk_class/walk_module's new `include_call?` branch,
        # mirroring the runtime effect via `register_static_include`)
        # this test failed with severity Error/tags {ExecutesCode} —
        # RiskAggregator's generic "unresolved" fallback, not
        # {DeletesFiles} — because `A.included_modules` stayed empty
        # for the whole walk and `run` was never found at all.
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          module M
            def run
              delete_fn()
            end
          end
          class A
            include M
          end
          A.new.run
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "static include recognition also works for nested module inclusion (module including a module)" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          module Inner
            def deep
              delete_fn()
            end
          end
          module Outer
            include Inner
          end
          class A
            include Outer
          end
          A.new.deep
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "an include argument that doesn't resolve to a known class/module doesn't crash the walk" do
        interp, _ = make_interp
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class A
            include SomeUnknownModule
          end
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        # register_static_include no-ops silently when the argument
        # doesn't resolve — the include statement itself contributes
        # no risk either way (see register_static_include's own
        # comment), so this just confirms the walk completes cleanly
        # rather than raising.
        summary.severity.should_not be_nil
      end
    end

    describe "include + super (Step 4 — super walks the real MRO, modules included)" do
      # Found while planning this step, not assumed: dispatch_super
      # previously jumped straight from the current method's own
      # class to `class.superclass`, with no notion of a module
      # sitting BETWEEN them. Fixed via RubyClass#ancestors (the real
      # linearized MRO) — dispatch_super now finds where the current
      # method's own class/module sits in self's ACTUAL ancestry and
      # searches everything after that position, rather than a fixed
      # one-hop jump.

      it "super from the class's own method reaches an included module's method BEFORE the superclass" do
        eval(<<-RUBY).should eq Value.string("A-M-Base")
        module M
          def greet
            "M-" + super
          end
        end
        class Base
          def greet
            "Base"
          end
        end
        class A < Base
          include M
          def greet
            "A-" + super
          end
        end
        A.new.greet
        RUBY
      end

      it "super called from INSIDE a module's own method reaches the superclass — the module itself has no superclass of its own to consult" do
        eval(<<-RUBY).should eq Value.string("M-Base")
        module M
          def greet
            "M-" + super
          end
        end
        class Base
          def greet
            "Base"
          end
        end
        class A < Base
          include M
        end
        A.new.greet
        RUBY
      end

      it "with multiple includes, super visits them in real MRO order (last included first)" do
        eval(<<-RUBY).should eq Value.string("A-M2-M1-Base")
        module M1
          def greet
            "M1-" + super
          end
        end
        module M2
          def greet
            "M2-" + super
          end
        end
        class Base
          def greet
            "Base"
          end
        end
        class A < Base
          include M1
          include M2
          def greet
            "A-" + super
          end
        end
        A.new.greet
        RUBY
      end

      it "nested module inclusion (module including a module) is fully reachable via super too" do
        eval(<<-RUBY).should eq Value.string("A-Outer-Inner-Base")
        module Inner
          def greet
            "Inner-" + super
          end
        end
        module Outer
          include Inner
          def greet
            "Outer-" + super
          end
        end
        class Base
          def greet
            "Base"
          end
        end
        class A < Base
          include Outer
          def greet
            "A-" + super
          end
        end
        A.new.greet
        RUBY
      end

      it "a class with NO included modules at all is completely unaffected — plain super still works exactly as before" do
        eval(<<-RUBY).should eq Value.string("Base-A")
        class Base
          def greet
            "Base"
          end
        end
        class A < Base
          def greet
            super + "-A"
          end
        end
        A.new.greet
        RUBY
      end

      it "R014 (no ancestor defines the method) still raised correctly when nothing anywhere in the chain has it, modules included" do
        expect_raises(RuntimeError, /only_here/) do
          eval(<<-RUBY)
          module M
          end
          class A
            include M
            def only_here
              super()
            end
          end
          A.new.only_here
          RUBY
        end
      end

      it "zsuper (bare super) still forwards current parameter values correctly when a module sits in between" do
        eval(<<-RUBY).should eq Value.int(3_i64)
        module M
          def add(x, y)
            super
          end
        end
        class Base
          def add(x, y)
            x + y
          end
        end
        class A < Base
          include M
        end
        A.new.add(1, 2)
        RUBY
      end

      it "an included module's method reaching a NATIVE superclass method via super still works" do
        interp, _ = make_interp
        risk = RiskProfile.new
        cls = RubyClass.new("Greeter")
        sym_id = interp.symbols.intern("greet").value
        cls.define_native_method(sym_id, risk) { |args| Value.string("native") }
        interp.define_global_class(cls)
        result = interp.eval(<<-RUBY)
        module M
          def greet
            "M-" + super()
          end
        end
        class Talker < Greeter
          include M
        end
        Talker.new.greet
        RUBY
        result.as_string.should eq "M-native"
      end
    end

    describe "include + respond_to? (no separate change needed — shared find_method/find_native_method)" do
      it "respond_to? correctly reports true for a method only reachable through an included module" do
        eval(<<-RUBY).should eq Value.bool(true)
        module M
          def greet
          end
        end
        class A
          include M
        end
        A.new.respond_to?(:greet)
        RUBY
      end

      it "respond_to? correctly reports false for a method not defined anywhere in the chain, module included" do
        eval(<<-RUBY).should eq Value.bool(false)
        module M
          def greet
          end
        end
        class A
          include M
        end
        A.new.respond_to?(:totally_unrelated)
        RUBY
      end
    end

    describe "include + super + RiskWalker (walk_super_target's own fix, found alongside dispatch_super's)" do
      it "a risky call reached via super through an included module surfaces its tags statically" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          module M
            def greet
              delete_fn()
            end
          end
          class Base
            def greet
            end
          end
          class A < Base
            include M
            def greet
              super
            end
          end
          A.new.greet
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end

      it "super called from inside a module's own method resolves statically too, reaching the superclass" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          module M
            def greet
              super
            end
          end
          class Base
            def greet
              delete_fn()
            end
          end
          class A < Base
            include M
          end
          A.new.greet
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end
    end

    describe "singleton-method super (Step 1 of the extend-support build-out — pre-existing bug, unrelated to include)" do
      # `def self.foo; super; end` previously searched find_method/
      # find_native_method (the INSTANCE tables) in
      # VM#dispatch_super's fallback branch — wrong table entirely,
      # since self here IS the class object itself, not an instance
      # of it. Fixed to search find_singleton_method/
      # find_native_singleton_method instead. Predates `include`/
      # `extend` entirely; fixed now as a prerequisite for `extend`
      # (which needs this path working correctly to be worth testing
      # against at all) rather than because `extend` itself caused it.

      it "a class method's super reaches the superclass's OWN class method, not an instance method of the same name" do
        eval(<<-RUBY).should eq Value.string("Base-self-A")
        class Base
          def self.greet
            "Base-self"
          end
        end
        class A < Base
          def self.greet
            super + "-A"
          end
        end
        A.greet
        RUBY
      end

      it "previously raised R014 incorrectly (searched the wrong table and found nothing) — now resolves cleanly" do
        # Explicit regression marker: before this fix, the test above
        # didn't just give a WRONG answer, it raised "no ancestor
        # defines the method" — Base's OWN instance table genuinely
        # has no `greet` (only Base's SINGLETON table does), so the
        # old buggy lookup found nothing at all.
        eval(<<-RUBY).should eq Value.string("ok")
        class Base
          def self.only_as_class_method
            "ok"
          end
        end
        class A < Base
          def self.only_as_class_method
            super
          end
        end
        A.only_as_class_method
        RUBY
      end

      it "a class method's super reaches a NATIVE singleton method on the superclass" do
        interp, _ = make_interp
        risk = RiskProfile.new
        cls = RubyClass.new("Base")
        sym_id = interp.symbols.intern("make").value
        cls.define_native_singleton_method(sym_id, risk) { |args| Value.string("native-make") }
        interp.define_global_class(cls)
        result = interp.eval(<<-RUBY)
        class A < Base
          def self.make
            "A-" + super()
          end
        end
        A.make
        RUBY
        result.as_string.should eq "A-native-make"
      end

      it "R014 still correctly raised when no ancestor's class method (singleton table) defines it at all" do
        expect_raises(RuntimeError, /only_here/) do
          eval(<<-RUBY)
          class Base
          end
          class A < Base
            def self.only_here
              super()
            end
          end
          A.only_here
          RUBY
        end
      end

      it "instance-method super is completely unaffected by this fix — still uses the ancestors-based instance resolution" do
        eval(<<-RUBY).should eq Value.string("Base-A")
        class Base
          def greet
            "Base"
          end
        end
        class A < Base
          def greet
            super + "-A"
          end
        end
        A.new.greet
        RUBY
      end

      it "RiskWalker's static resolution of singleton super already worked correctly (walk_super_target needed no code change) — confirmed rather than assumed" do
        interp, _ = make_interp
        risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
        register_risky_module(interp, "delete_fn", risk)
        walker = RiskWalker.new(interp)
        body = risk_walker_test_parse(<<-RUBY)
          class Base
            def self.greet
              delete_fn()
            end
          end
          class A < Base
            def self.greet
              super
            end
          end
          A.greet
        RUBY
        summary = RiskAggregator.summarize(walker.walk_body(body))
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles}
      end
    end

    describe "extend (Step 2 — registration only, no method resolution yet)" do
      # Mirrors include's own Step 2 exactly, into extended_modules
      # instead of included_modules. `extend` now registers the
      # module into the extending class's own `extended_modules` —
      # actual method lookup honoring it (RubyClass#
      # find_singleton_method/find_native_singleton_method walking
      # extended_modules) is Step 3, not built yet.

      it "extend adds the module to the extending class's extended_modules" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M
        end
        class A
          extend M
        end
        RUBY
        a = interp.get_global("A").as_rclass
        m = interp.get_global("M").as_rclass
        a.extended_modules.should eq [m]
      end

      it "extend does NOT also add to included_modules — genuinely separate lists" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M
        end
        class A
          extend M
        end
        RUBY
        a = interp.get_global("A").as_rclass
        a.included_modules.should be_empty
      end

      it "extend works inside a module body too, not just a class body" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M
        end
        module N
          extend M
        end
        RUBY
        n = interp.get_global("N").as_rclass
        m = interp.get_global("M").as_rclass
        n.extended_modules.should eq [m]
      end

      it "multiple extends are stored in SOURCE order (insertion order — MRO reversal is Step 3's concern, not storage's)" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module M1
        end
        module M2
        end
        class A
          extend M1
          extend M2
        end
        RUBY
        a = interp.get_global("A").as_rclass
        m1 = interp.get_global("M1").as_rclass
        m2 = interp.get_global("M2").as_rclass
        a.extended_modules.should eq [m1, m2]
      end

      it "`extend` returns self (the extending class), matching real Ruby's Module#extend" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
        module M
        end
        class A
          def self.try_extend
            extend M
          end
        end
        A.try_extend
        RUBY
        result.as_rclass.name.should eq "A"
      end

      it "a class with no extend at all has an empty extended_modules, unaffected" do
        interp, _ = make_interp
        interp.eval("class A\nend")
        a = interp.get_global("A").as_rclass
        a.extended_modules.should be_empty
      end

      it "include and extend can both be used on the same class, into their own separate lists" do
        interp, _ = make_interp
        interp.eval(<<-RUBY)
        module Inc
        end
        module Ext
        end
        class A
          include Inc
          extend Ext
        end
        RUBY
        a = interp.get_global("A").as_rclass
        inc = interp.get_global("Inc").as_rclass
        ext = interp.get_global("Ext").as_rclass
        a.included_modules.should eq [inc]
        a.extended_modules.should eq [ext]
      end
    end

    describe "extend (Step 3 — actual method resolution)" do
      # find_singleton_method/find_native_singleton_method (RubyClass)
      # now walk extended_modules — this is the step that makes
      # `extend` actually do something. Mirrors include's own Step 3
      # exactly, on the singleton side.

      it "a class extending a module can call the module's method as a CLASS method" do
        eval(<<-RUBY).should eq Value.string("hi from M")
        module M
          def greet
            "hi from M"
          end
        end
        class A
          extend M
        end
        A.greet
        RUBY
      end

      it "the class's OWN class method wins over an extended module's same-named method" do
        eval(<<-RUBY).should eq Value.string("A's own")
        module M
          def greet
            "from M"
          end
        end
        class A
          extend M
          def self.greet
            "A's own"
          end
        end
        A.greet
        RUBY
      end

      it "with multiple extends, the LAST one wins (real Ruby MRO — closest to the class)" do
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
        class A
          extend M1
          extend M2
        end
        A.greet
        RUBY
      end

      it "an extended module's method is NOT callable on an instance — extend affects the singleton chain only" do
        expect_raises(RuntimeError, /greet/) do
          eval(<<-RUBY)
          module M
            def greet
              "from M"
            end
          end
          class A
            extend M
          end
          A.new.greet
          RUBY
        end
      end

      it "an included module's method is NOT callable as a class method — include affects the instance chain only" do
        expect_raises(RuntimeError, /greet/) do
          eval(<<-RUBY)
          module M
            def greet
              "from M"
            end
          end
          class A
            include M
          end
          A.greet
          RUBY
        end
      end

      it "extending a module that itself includes another module surfaces the included module's methods too" do
        eval(<<-RUBY).should eq Value.string("deep")
        module Inner
          def deep_method
            "deep"
          end
        end
        module Outer
          include Inner
        end
        class A
          extend Outer
        end
        A.deep_method
        RUBY
      end

      it "respond_to? correctly reports true for a class method only reachable through an extended module" do
        eval(<<-RUBY).should eq Value.bool(true)
        module M
          def greet
          end
        end
        class A
          extend M
        end
        A.respond_to?(:greet)
        RUBY
      end
    end
  end
end
