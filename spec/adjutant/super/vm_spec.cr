require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "super (Step 1 — explicit args)" do
      # Step 1 of the super-dispatch rewrite (see SCOPE.md and the
      # 2026-08-09 handoff). Prior to this, `super` compiled to an
      # ordinary call literally named "super", which never resolved
      # to anything — every `super` call raised R008 unconditionally,
      # in every context. These specs cover the first real dispatch:
      # explicit-argument super, resolving from the DEFINING class's
      # superclass (not self's own class), with self unchanged.

      it "reaches the immediate superclass's method" do
        eval(<<-RUBY).as_string.should eq "A"
        class A
          def greet
            "A"
          end
        end
        class B < A
          def greet
            super()
          end
        end
        B.new.greet
        RUBY
      end

      it "passes explicit arguments through to the superclass method" do
        eval(<<-RUBY).as_int.should eq 3
        class A
          def add(x, y)
            x + y
          end
        end
        class B < A
          def add(x, y)
            super(x, y)
          end
        end
        B.new.add(1, 2)
        RUBY
      end

      it "resolution starts one level above where the CURRENT method is defined, not above self's own class" do
        # C < B < A, all three define `greet`. Calling super from B's
        # greet must reach A's, not C's — even though self is a C
        # instance. This is the check that actually distinguishes
        # "start at self.class.superclass" (wrong: would search from
        # B down, potentially re-finding B's own method or looping)
        # from "start at the DEFINING class's superclass" (right).
        eval(<<-RUBY).as_string.should eq "B-A"
        class A
          def greet
            "A"
          end
        end
        class B < A
          def greet
            "B-" + super()
          end
        end
        class C < B
          def greet
            super()
          end
        end
        C.new.greet
        RUBY
      end

      it "runs the superclass method with self still bound to the original receiver" do
        eval(<<-RUBY).as_int.should eq 5
        class A
          def set
            @x = 5
          end
        end
        class B < A
          def set
            super()
          end
          def x
            @x
          end
        end
        b = B.new
        b.set
        b.x
        RUBY
      end

      it "reaches a native superclass method" do
        # Registers a real native method on a real global RubyClass
        # (via define_global_class, same path Builtins uses for
        # Integer/String/...), then a script subclass overrides it
        # and calls super — exercising dispatch_super's
        # find_native_method branch, not just find_method's.
        interp, _ = make_interp
        cls = RubyClass.new("Greeter")
        sym_id = interp.symbols.intern("greet").value
        cls.define_native_method(sym_id, RiskProfile.none) { |args| Value.string("native") }
        interp.define_global_class(cls)
        result = interp.eval(<<-RUBY)
        class Talker < Greeter
          def greet
            super()
          end
        end
        Talker.new.greet
        RUBY
        result.as_string.should eq "native"
      end

      it "raises when no ancestor defines the method (temporary R008 shape, pending Step 2)" do
        expect_raises(RuntimeError, /only_here/) do
          eval(<<-RUBY)
          class A
          end
          class B < A
            def only_here
              super()
            end
          end
          B.new.only_here
          RUBY
        end
      end

      it "raises when the class has no explicit superclass beyond Object and Object doesn't define it either" do
        expect_raises(RuntimeError) do
          eval(<<-RUBY)
          class A
            def totally_novel_method_name
              super()
            end
          end
          A.new.totally_novel_method_name
          RUBY
        end
      end
    end
  end
end
