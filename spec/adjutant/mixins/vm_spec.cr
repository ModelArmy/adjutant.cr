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
  end
end
