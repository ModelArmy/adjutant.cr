require "../spec_helper"

module Adjutant
  # CounterObject is the test's stand-in for a stateful builtin like a
  # future File — a RubyObject subclass carrying real Crystal state
  # (here, a plain Int32 counter) instead of ivars in the shared
  # ivars : Hash(Int32, Value) table. Exercises the exact shape this
  # session's work is for: a native singleton `new` allocates the
  # subclass directly, and native instance methods cast the receiver
  # back to it.
  private class CounterObject < RubyObject
    property count : Int32

    def initialize(rclass : RubyClass, start : Int32)
      super(rclass)
      @count = start
    end
  end

  # Builds a `Counter` RubyClass with a native singleton `new(start)`
  # that allocates a CounterObject, plus `increment`/`value` native
  # instance methods that operate on the real Int32 state. Registered
  # fresh per test via `interp` so each spec gets an isolated class —
  # mirrors how builtins.cr's bootstrap_* functions are structured,
  # scaled down to spec use.
  private def self.bootstrap_counter(interp : Interpreter,
                                     new_risk : RiskProfile = RiskProfile.none) : RubyClass
    cls = RubyClass.new("Counter")

    new_sym = interp.symbols.intern("new").value
    cls.define_native_singleton_method(new_sym, new_risk) do |args|
      start = args.size > 1 ? args[1].as_int.to_i32 : 0
      Value.robject(CounterObject.new(cls, start))
    end

    inc_sym = interp.symbols.intern("increment").value
    cls.define_native_method(inc_sym, RiskProfile.none) do |args|
      counter = args.first.as_robject.as(CounterObject)
      counter.count += 1
      Value.int(counter.count.to_i64)
    end

    value_sym = interp.symbols.intern("value").value
    cls.define_native_method(value_sym, RiskProfile.none) do |args|
      counter = args.first.as_robject.as(CounterObject)
      Value.int(counter.count.to_i64)
    end

    interp.define_global_class(cls)
  end

  describe "Native singleton methods (.new)" do
    it "define_native_singleton_method stores a callable under the symbol id" do
      interp, _ = make_interp
      cls = RubyClass.new("Widget")
      sym_id = interp.symbols.intern("new").value
      cls.define_native_singleton_method(sym_id, RiskProfile.none) { |args| Value.nil_value }
      cls.find_native_singleton_method(sym_id).should_not be_nil
    end

    it "find_native_singleton_method returns nil for an unregistered symbol" do
      interp, _ = make_interp
      cls = RubyClass.new("Widget")
      sym_id = interp.symbols.intern("new").value
      cls.find_native_singleton_method(sym_id).should be_nil
    end

    it "find_native_singleton_method walks the superclass chain" do
      interp, _ = make_interp
      parent = RubyClass.new("Base")
      child = RubyClass.new("Derived", parent)
      sym_id = interp.symbols.intern("new").value
      parent.define_native_singleton_method(sym_id, RiskProfile.none) { |args| Value.nil_value }
      child.find_native_singleton_method(sym_id).should_not be_nil
    end

    it "a subclass's own native new shadows the parent's" do
      interp, _ = make_interp
      parent = RubyClass.new("Base")
      child = RubyClass.new("Derived", parent)
      sym_id = interp.symbols.intern("new").value
      parent.define_native_singleton_method(sym_id, RiskProfile.none) { |args| Value.string("base") }
      child.define_native_singleton_method(sym_id, RiskProfile.none) { |args| Value.string("derived") }
      child.find_native_singleton_method(sym_id).not_nil!.call([] of Value, nil, FakeContext.new)
        .as_string.should eq "derived"
    end
  end

  describe "VM dispatch: Foo.new with a native singleton method" do
    it "calls the native new and returns its constructed object" do
      interp, _ = make_interp
      bootstrap_counter(interp)
      result = interp.eval("c = Counter.new(5)\nc.value")
      result.as_int.should eq 5
    end

    it "the constructed object is the real RubyObject subclass, not a bare RubyObject" do
      interp, _ = make_interp
      bootstrap_counter(interp)
      result = interp.eval("Counter.new(0)")
      result.robject?.should be_true
      result.as_robject.should be_a(CounterObject)
    end

    it "native instance methods can mutate the subclass's real state" do
      interp, _ = make_interp
      bootstrap_counter(interp)
      result = interp.eval(<<-RUBY)
        c = Counter.new(0)
        c.increment
        c.increment
        c.increment
        c.value
      RUBY
      result.as_int.should eq 3
    end

    it "defaults the constructor arg when none is given" do
      interp, _ = make_interp
      bootstrap_counter(interp)
      result = interp.eval("Counter.new.value")
      result.as_int.should eq 0
    end

    it "a class with no native new still uses the generic script-initialize path" do
      interp, _ = make_interp
      interp.eval(<<-RUBY)
        class Widget
          def initialize(n)
            @n = n
          end

          def n
            @n
          end
        end
      RUBY
      result = interp.eval("Widget.new(7).n")
      result.as_int.should eq 7
    end

    it "wraps a native new's raised exception as a runtime error" do
      interp, _ = make_interp
      cls = RubyClass.new("Bomb")
      sym_id = interp.symbols.intern("new").value
      cls.define_native_singleton_method(sym_id, RiskProfile.none) { |args| raise "boom" }
      interp.define_global_class(cls)
      expect_raises(RuntimeError, /Native call error: boom/) do
        interp.eval("Bomb.new")
      end
    end
  end

  describe "RiskWalker: ClassName.new with a native singleton method" do
    it "a pure native new resolves to Info, not unconditional zero-risk silence" do
      interp, _ = make_interp
      bootstrap_counter(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new("Counter.new(0)").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
    end

    it "a risky native new surfaces its real RiskProfile, not zero risk" do
      interp, _ = make_interp
      risk = RiskProfile.new(tags: Set{RiskTag::WritesFiles}, severity: Severity::Warning)
      bootstrap_counter(interp, new_risk: risk)
      walker = RiskWalker.new(interp)
      body = Parser.new("Counter.new(0)").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Warning
      summary.tags.should eq Set{RiskTag::WritesFiles}
    end

    it "a class with no native new still resolves .new as zero risk (unchanged behavior)" do
      interp, _ = make_interp
      interp.eval("class Widget\nend")
      walker = RiskWalker.new(interp)
      body = Parser.new("Widget.new").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Info
    end

    it "an unresolvable class's .new is still RiskUnresolved" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = Parser.new("Ghost.new").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.path.first.should contain "unresolved"
    end

    it "risky construction via a var is not silently dropped downstream" do
      interp, _ = make_interp
      risk = RiskProfile.new(tags: Set{RiskTag::WritesFiles}, severity: Severity::Warning)
      bootstrap_counter(interp, new_risk: risk)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        c = Counter.new(0)
        c.increment
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.tags.should eq Set{RiskTag::WritesFiles}
    end
  end

  # Minimal NativeCallContext for direct NativeCallable#call tests that
  # don't go through the VM — mirrors the one in
  # ruby_class_native_methods_spec.cr.
  private class FakeContext
    include NativeCallContext

    def initialize(@filename : String = "<spec>", @line : Int32 = 0)
    end

    def invoke(proc : ScriptProc, args : Array(Value)) : Value
      Value.nil_value
    end

    def values_equal?(a : Value, b : Value) : Bool
      a == b
    end

    # No-op — these direct-NativeCallable tests don't exercise risk
    # flow enforcement, just method dispatch. See
    # risk_flow_enforcement_spec.cr for real declare_sensitivity
    # coverage, which goes through the actual VM.
    def declare_sensitivity(tag : RiskTag, kind : ProvenanceKind, origin : String,
                            sensitivity : Sensitivity? = nil) : Nil
    end
  end
end
