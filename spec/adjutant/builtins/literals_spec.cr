require "../../spec_helper"

module Adjutant
  # Covers Phase 2 of the base-types work: NilClass, TrueClass,
  # FalseClass, and Symbol — the literal/singleton builtin classes.
  # Real Ruby genuinely has TWO distinct classes for true/false, not
  # one shared Boolean, which is the main thing worth getting right
  # here; everything else follows Integer's existing bootstrap pattern
  # closely.
  describe "NilClass" do
    it "nil.class is NilClass" do
      interp, _ = make_interp
      result = interp.eval("nil.class == NilClass")
      result.truthy?.should be_true
    end

    it "nil.is_a?(NilClass) is true" do
      interp, _ = make_interp
      result = interp.eval("nil.is_a?(NilClass)")
      result.truthy?.should be_true
    end

    it "NilClass.superclass is Object" do
      interp, _ = make_interp
      result = interp.eval("NilClass.superclass == Object")
      result.truthy?.should be_true
    end

    it "nil.to_s is the empty string, matching real Ruby" do
      interp, _ = make_interp
      result = interp.eval("nil.to_s")
      result.as_string.should eq ""
    end

    it "nil.nil? is true — the existing universal fallback, unaffected by this bootstrap" do
      interp, _ = make_interp
      result = interp.eval("nil.nil?")
      result.truthy?.should be_true
    end

    it "5.nil? is false" do
      interp, _ = make_interp
      result = interp.eval("5.nil?")
      result.falsy?.should be_true
    end
  end

  describe "TrueClass and FalseClass — two distinct classes, not one shared Boolean" do
    it "true.class is TrueClass" do
      interp, _ = make_interp
      result = interp.eval("true.class == TrueClass")
      result.truthy?.should be_true
    end

    it "false.class is FalseClass" do
      interp, _ = make_interp
      result = interp.eval("false.class == FalseClass")
      result.truthy?.should be_true
    end

    it "true.class is NOT FalseClass, and vice versa" do
      interp, _ = make_interp
      result = interp.eval("[true.class == FalseClass, false.class == TrueClass]")
      result.as_array.map(&.truthy?).should eq [false, false]
    end

    it "true.is_a?(TrueClass) and false.is_a?(FalseClass)" do
      interp, _ = make_interp
      result = interp.eval("[true.is_a?(TrueClass), false.is_a?(FalseClass)]")
      result.as_array.map(&.truthy?).should eq [true, true]
    end

    it "true.is_a?(FalseClass) is false — the two classes don't cross-match" do
      interp, _ = make_interp
      result = interp.eval("true.is_a?(FalseClass)")
      result.falsy?.should be_true
    end

    it "both TrueClass and FalseClass default to Object as their superclass" do
      interp, _ = make_interp
      result = interp.eval("[TrueClass.superclass == Object, FalseClass.superclass == Object]")
      result.as_array.map(&.truthy?).should eq [true, true]
    end

    it "true.to_s and false.to_s round-trip correctly" do
      interp, _ = make_interp
      result = interp.eval("[true.to_s, false.to_s]")
      result.as_array.map(&.as_string).should eq ["true", "false"]
    end
  end

  describe "Symbol" do
    it ":foo.class is Symbol" do
      interp, _ = make_interp
      result = interp.eval(":foo.class == Symbol")
      result.truthy?.should be_true
    end

    it ":foo.is_a?(Symbol) is true" do
      interp, _ = make_interp
      result = interp.eval(":foo.is_a?(Symbol)")
      result.truthy?.should be_true
    end

    it "Symbol.superclass is Object" do
      interp, _ = make_interp
      result = interp.eval("Symbol.superclass == Object")
      result.truthy?.should be_true
    end

    it ":foo.to_s returns the name without the leading colon" do
      interp, _ = make_interp
      result = interp.eval(":foo.to_s")
      result.as_string.should eq "foo"
    end

    it ":foo.to_sym is identity" do
      interp, _ = make_interp
      result = interp.eval(":foo.to_sym == :foo")
      result.truthy?.should be_true
    end

    it "two symbol literals with the same name are == (already correct via Op::Eq, unaffected by this bootstrap)" do
      interp, _ = make_interp
      result = interp.eval(":foo == :foo")
      result.truthy?.should be_true
    end

    it "two different symbols are not ==" do
      interp, _ = make_interp
      result = interp.eval(":foo == :bar")
      result.falsy?.should be_true
    end
  end

  describe "builtin_class_for resolves all four kinds distinctly" do
    it "respond_to? works for these classes' own native methods" do
      interp, _ = make_interp
      result = interp.eval("[nil.respond_to?(:to_s), true.respond_to?(:to_s), :foo.respond_to?(:to_sym)]")
      result.as_array.map(&.truthy?).should eq [true, true, true]
    end

    it "respond_to? is false for a method not on that class" do
      interp, _ = make_interp
      result = interp.eval(":foo.respond_to?(:nope)")
      result.falsy?.should be_true
    end
  end
end
