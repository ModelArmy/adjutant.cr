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

      it "raises R014 (NoMethodError) when no ancestor defines the method" do
        error = expect_raises(RuntimeError, /only_here/) do
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
        error.diagnostic.not_nil!.code.should eq "R014"
      end

      it "the R014 error is script-catchable as NoMethodError, matching Ruby" do
        eval(<<-RUBY).as_string.should eq "caught"
        class A
        end
        class B < A
          def only_here
            super()
          end
        end
        begin
          B.new.only_here
        rescue NoMethodError => e
          "caught"
        end
        RUBY
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

    describe "super (Step 3 — zsuper: forwarding current parameter values)" do
      it "bare `super` forwards the originally-passed positional argument values" do
        eval(<<-RUBY).as_int.should eq 3
        class A
          def add(x, y)
            x + y
          end
        end
        class B < A
          def add(x, y)
            super
          end
        end
        B.new.add(1, 2)
        RUBY
      end

      it "bare `super` forwards CURRENT (reassigned) values, not the original ones" do
        # The defining Ruby distinction between zsuper and super(): a
        # param mutated before the super call is forwarded with its
        # NEW value.
        eval(<<-RUBY).as_int.should eq 30
        class A
          def double(x)
            x * 2
          end
        end
        class B < A
          def double(x)
            x = 15
            super
          end
        end
        B.new.double(1)
        RUBY
      end

      it "explicit `super()` does NOT forward args, even though bare `super` would" do
        # Calling with explicitly zero args leaves A#add's required
        # params unbound (nil) — bind_args is silently permissive
        # about missing required positional args, same as an
        # ordinary direct call with too few arguments would be. The
        # point under test is that x/y are nil here, NOT what they'd
        # be forwarded as — i.e. that `super()` genuinely passed
        # nothing, unlike bare `super` in the tests above.
        eval(<<-RUBY).as_bool.should eq true
        class A
          def add(x, y)
            x.nil? && y.nil?
          end
        end
        class B < A
          def add(x, y)
            super()
          end
        end
        B.new.add(1, 2)
        RUBY
      end

      it "forwards a default param's resolved value" do
        eval(<<-RUBY).as_int.should eq 7
        class A
          def add(x, y)
            x + y
          end
        end
        class B < A
          def add(x, y = 5)
            super
          end
        end
        B.new.add(2)
        RUBY
      end

      it "re-expands a splat param's CURRENT elements as separate positional args" do
        eval(<<-RUBY).as_int.should eq 6
        class A
          def sum(*nums)
            total = 0
            nums.each { |n| total = total + n }
            total
          end
        end
        class B < A
          def sum(*nums)
            super
          end
        end
        B.new.sum(1, 2, 3)
        RUBY
      end

      it "forwards a kwarg param as a keyword argument, not positionally" do
        eval(<<-RUBY).as_string.should eq "hi bob"
        class A
          def greet(name:)
            "hi " + name
          end
        end
        class B < A
          def greet(name:)
            super
          end
        end
        B.new.greet(name: "bob")
        RUBY
      end
    end

    describe "super (Step 4 — implicit block forwarding)" do
      it "bare `super` forwards the enclosing method's block" do
        eval(<<-RUBY).as_int.should eq 20
        class A
          def run
            yield 10
          end
        end
        class B < A
          def run
            super
          end
        end
        B.new.run { |x| x * 2 }
        RUBY
      end

      it "explicit `super()` also forwards the enclosing method's block" do
        # Real Ruby forwards the block implicitly for BOTH forms —
        # only the ARGUMENTS differ between bare `super` and
        # `super()`, never the block.
        eval(<<-RUBY).as_int.should eq 6
        class A
          def run
            yield 5
          end
        end
        class B < A
          def run
            super()
          end
        end
        B.new.run { |x| x + 1 }
        RUBY
      end

      it "the forwarded block still closes over its ORIGINAL defining scope, not the frame it's forwarded through" do
        # Mirrors methods_and_calls/vm_spec.cr's own "block captures
        # local from its defining scope via yield" — same property,
        # now through an extra super hop. `total` lives in the
        # TOP-LEVEL frame, where the block literal `{ |x| total +=
        # x }` was actually written; B#run forwards the SAME block
        # onward to A#run's `yield` without ever re-attaching it to
        # either method's own frame.
        eval(<<-RUBY).as_int.should eq 6
        total = 0
        class A
          def run
            yield 1
            yield 2
            yield 3
          end
        end
        class B < A
          def run
            super
          end
        end
        B.new.run { |x| total += x }
        total
        RUBY
      end
    end

    describe "super (parser fixes — bare super followed by a binary operator)" do
      # Found via a hand-written test script. Two separate parser bugs
      # stacked here, both now fixed:
      #
      #   1. parse_super's own bare-arg branch had no argument-start
      #      guard, so `super + 4` first parsed as `super(+4)` — an
      #      explicit unary-plus argument — silently discarding the 4
      #      (A#greet takes no params) and leaving nothing for `+` to
      #      apply to. Fixed via arg_follows_no_paren?, the same guard
      #      parse_raise already used for this exact ambiguity.
      #   2. Even after (1), `super + 4` AT STATEMENT POSITION (not a
      #      sub-expression — i.e. the very first token of a method
      #      body/line) still failed differently: parse_statement had
      #      its OWN separate `KwSuper => parse_super` shortcut that
      #      returned immediately, bypassing parse_expr_statement's
      #      full pipeline (operator-precedence climbing among it) —
      #      so `super` alone became one statement and `+ 4` a
      #      completely independent SECOND one, silently discarding
      #      super's value (`super + 4` evaluated to plain `4`). Fixed
      #      by removing that shortcut so KwSuper falls through to
      #      parse_expr_statement uniformly, same as any other
      #      expression-shaped statement.
      it "`super + 4` adds to super's result, rather than passing 4 as an argument" do
        eval(<<-RUBY).as_int.should eq 7
        class A
          def greet
            3
          end
        end
        class B < A
          def greet
            super + 4
          end
        end
        B.new.greet
        RUBY
      end

      it "`super + \"str\"` concatenates with super's result, same shape with strings" do
        eval(<<-RUBY).as_string.should eq "hi bob"
        class X
          def greet
            "hi "
          end
        end
        class Y < X
          def greet
            super + "bob"
          end
        end
        Y.new.greet
        RUBY
      end
    end
  end
end
