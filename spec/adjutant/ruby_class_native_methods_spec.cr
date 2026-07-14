require "../spec_helper"

module Adjutant
  describe "RubyClass native methods" do
    it "define_native_method stores a callable under the symbol id" do
      interp, _ = make_interp
      cls = RubyClass.new("Widget")
      sym_id = interp.symbols.intern("ping").value
      cls.define_native_method(sym_id, RiskProfile.none) { |args| Value.string("pong") }
      cls.find_native_method(sym_id).should_not be_nil
    end

    it "find_native_method returns nil for an unregistered symbol" do
      interp, _ = make_interp
      cls = RubyClass.new("Widget")
      sym_id = interp.symbols.intern("missing").value
      cls.find_native_method(sym_id).should be_nil
    end

    it "find_native_method walks the superclass chain" do
      interp, _ = make_interp
      parent = RubyClass.new("Animal")
      child = RubyClass.new("Dog", parent)
      sym_id = interp.symbols.intern("speak").value
      parent.define_native_method(sym_id, RiskProfile.none) { |args| Value.string("...") }
      child.find_native_method(sym_id).should_not be_nil
    end

    it "a native method defined on the subclass shadows the parent's" do
      interp, _ = make_interp
      parent = RubyClass.new("Animal")
      child = RubyClass.new("Dog", parent)
      sym_id = interp.symbols.intern("speak").value
      parent.define_native_method(sym_id, RiskProfile.none) { |args| Value.string("generic") }
      child.define_native_method(sym_id, RiskProfile.none) { |args| Value.string("woof") }
      child.find_native_method(sym_id).not_nil!.call([] of Value, nil, FakeContext.new).as_string.should eq "woof"
    end

    it "carries the RiskProfile passed at registration" do
      interp, _ = make_interp
      cls = RubyClass.new("Widget")
      sym_id = interp.symbols.intern("delete!").value
      risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
      cls.define_native_method(sym_id, risk) { |args| Value.nil_value }
      cls.find_native_method(sym_id).not_nil!.risk.should eq risk
    end

    # Note: define_native_method's `risk` parameter has no default value
    # — omitting it is a compile-time error in Crystal, not something a
    # runtime spec can exercise. See the method's docs in ruby_class.cr.
  end

  describe "VM dispatch to native methods" do
    it "calls a receiver's native method" do
      interp, _ = make_interp
      cls = RubyClass.new("Greeter")
      sym_id = interp.symbols.intern("greet").value
      cls.define_native_method(sym_id, RiskProfile.none) { |args| Value.string("hello") }
      obj = RubyObject.new(cls)
      # Directly exercise dispatch via a script that receives the object
      # through a native function, since there is no literal syntax for
      # an ad-hoc RubyClass instance from script source.
      interp.modules.register("test/native_methods") do |i|
        i.define_native("make_greeter") { |_| Value.robject(obj) }
      end
      interp.modules.require("test/native_methods", interp)
      result = interp.eval(%(g = make_greeter()\ng.greet))
      result.as_string.should eq "hello"
    end

    it "script-defined methods take priority over native methods of the same name" do
      interp, _ = make_interp
      cls = RubyClass.new("Greeter")
      sym_id = interp.symbols.intern("greet").value
      cls.define_native_method(sym_id, RiskProfile.none) { |args| Value.string("native") }
      obj = RubyObject.new(cls)
      interp.modules.register("test/native_methods_shadow") do |i|
        i.define_native("make_greeter") { |_| Value.robject(obj) }
      end
      interp.modules.require("test/native_methods_shadow", interp)
      # Re-open the class from script to add a script-level method of the
      # same name — dispatch_call checks find_method before
      # find_native_method, so the script version must win.
      interp.eval(<<-RUBY)
        class Greeter
          def greet
            "scripted"
          end
        end
      RUBY
      script_cls = interp.get_global("Greeter").as_rclass
      cls.define_method(sym_id, script_cls.find_method(sym_id).not_nil!)
      result = interp.eval(%(g = make_greeter()\ng.greet))
      result.as_string.should eq "scripted"
    end

    it "wraps a native method's raised exception as a runtime error" do
      interp, _ = make_interp
      cls = RubyClass.new("Bomb")
      sym_id = interp.symbols.intern("explode").value
      cls.define_native_method(sym_id, RiskProfile.none) { |args| raise "boom" }
      obj = RubyObject.new(cls)
      interp.modules.register("test/native_methods_error") do |i|
        i.define_native("make_bomb") { |_| Value.robject(obj) }
      end
      interp.modules.require("test/native_methods_error", interp)
      expect_raises(RuntimeError, /Native call error: boom/) do
        interp.eval(%(b = make_bomb()\nb.explode))
      end
    end
  end

  # Minimal NativeCallContext for direct NativeCallable#call tests that
  # don't go through the VM.
  private class FakeContext
    include NativeCallContext

    def initialize(@filename : String = "<spec>", @line : Int32 = 0)
    end

    def invoke(proc : ScriptProc, args : Array(Value)) : Value
      Value.nil_value
    end

    # Minimal but real, not a stub — a direct-NativeCallable test that
    # exercises a method relying on == (e.g. Array#include?) needs
    # actual comparison semantics, not just a type-checking placeholder.
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
