require "../spec_helper"

module Adjutant
  # Covers the gap this session closes: `def self.foo` inside a class
  # body now actually attaches to the class (previously silently
  # leaked into globals, discarding the receiver — see
  # Op::DefSingleton), class ivars (@x set directly in a class body,
  # or read/written from a `def self.foo`) now have real storage of
  # their own on RubyClass, and — the subtle part — that storage is a
  # genuinely separate slot from an instance's own @x of the same
  # name, and separate again from a @@x cvar of the same name.
  describe "Script-defined singleton methods and class ivars" do
    it "the driving test case: class ivar, instance ivar, and cvar are three independent slots" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          @x = 6
          def self.x; @x; end
          def initialize; @x = 2; @@x = 7; end
          def x; @x; end
          def aax; @@x; end
          def self.aax; @@x; end
        end

        (A.x == 6) && (A.new.x == 2) && (A.aax == 7) && (A.aax == A.new.aax)
      RUBY
      result.truthy?.should be_true
    end

    it "def self.foo attaches to the class, not to globals" do
      interp, _ = make_interp
      interp.eval(<<-RUBY)
        class A
          def self.greet; "hi"; end
        end
      RUBY
      # If DefSingleton still leaked into globals under the bare name,
      # this would find and run it, returning "hi". A bare reference to
      # a name that isn't a local, global, or defined identifier raises —
      # it must NOT be "hi".
      expect_raises(RuntimeError) do
        interp.eval("greet")
      end
    end

    it "a bare-name global with the same name as a singleton method is unaffected" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        def greet; "global"; end
        class A
          def self.greet; "singleton"; end
        end
        [greet, A.greet]
      RUBY
      result.as_array.map(&.as_string).should eq ["global", "singleton"]
    end

    it "a class ivar set in the class body is readable from a singleton method" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          @count = 10
          def self.count; @count; end
        end
        A.count
      RUBY
      result.as_int.should eq 10
    end

    it "a class ivar is NOT visible to instance methods (separate slot, not inherited)" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          @x = 99
          def x; @x; end
        end
        A.new.x
      RUBY
      result.null?.should be_true
    end

    it "an instance's own @x does not leak back to the class ivar" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          def self.x; @x; end
          def initialize; @x = 5; end
        end
        A.new
        A.x
      RUBY
      result.null?.should be_true
    end

    it "two instances have independent ivars" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          def initialize(n); @n = n; end
          def n; @n; end
        end
        a = A.new(1)
        b = A.new(2)
        [a.n, b.n]
      RUBY
      result.as_array.map(&.as_int).should eq [1, 2]
    end

    it "a cvar set via an instance method is visible from a singleton method" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          def set(v); @@shared = v; end
          def self.shared; @@shared; end
        end
        A.new.set(42)
        A.shared
      RUBY
      result.as_int.should eq 42
    end

    it "a cvar written from a singleton method is visible to instances" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          def self.set(v); @@shared = v; end
          def shared; @@shared; end
        end
        A.set(3)
        A.new.shared
      RUBY
      result.as_int.should eq 3
    end

    it "def self.foo can take and use parameters" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          def self.double(n); n * 2; end
        end
        A.double(21)
      RUBY
      result.as_int.should eq 42
    end

    it "a singleton method is inherited by a subclass" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          def self.kind; "A"; end
        end
        class B < A
        end
        B.kind
      RUBY
      result.as_string.should eq "A"
    end

    it "a subclass's own singleton method shadows the parent's" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class A
          def self.kind; "A"; end
        end
        class B < A
          def self.kind; "B"; end
        end
        [A.kind, B.kind]
      RUBY
      result.as_array.map(&.as_string).should eq ["A", "B"]
    end

    it "calling an undefined singleton method on a class raises, not silently returns nil" do
      interp, _ = make_interp
      interp.eval("class A; end")
      expect_raises(RuntimeError) do
        interp.eval("A.nope")
      end
    end
  end

  describe "RiskWalker: class-receiver calls resolve against singleton methods" do
    it "A.method (script singleton) resolves to that method's own body risk, not RiskUnresolved" do
      interp, _ = make_interp
      interp.eval(<<-RUBY)
        class A
          def self.greet; "hi"; end
        end
      RUBY
      walker = RiskWalker.new(interp)
      body = Parser.new("A.greet").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
    end

    it "A.method (native singleton, non-new) surfaces its real RiskProfile" do
      interp, _ = make_interp
      cls = RubyClass.new("Widget")
      risk = RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning)
      sym = interp.symbols.intern("ping").value
      cls.define_native_singleton_method(sym, risk) { |args| Value.nil_value }
      interp.define_global_class(cls)
      walker = RiskWalker.new(interp)
      body = Parser.new("Widget.ping").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Warning
      summary.tags.should eq Set{RiskTag::NetworkEgress}
    end

    it "A.method for an undefined singleton method is RiskUnresolved" do
      interp, _ = make_interp
      interp.eval("class A; end")
      walker = RiskWalker.new(interp)
      body = Parser.new("A.nope").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
    end

    it "A.new still routes through the constructor path, unaffected by the class-receiver change" do
      interp, _ = make_interp
      interp.eval("class A; end")
      walker = RiskWalker.new(interp)
      body = Parser.new("A.new").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
    end

    it "an unresolvable class's method call is still RiskUnresolved" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = Parser.new("Ghost.method").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
    end
  end
end
