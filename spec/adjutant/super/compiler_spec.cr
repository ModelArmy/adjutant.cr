require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "super (Step 1 — explicit args)" do
      # Step 1 of the super-dispatch rewrite (see SCOPE.md): `super`
      # now compiles to a dedicated Op::Super rather than an ordinary
      # Op::Call to a literal method named "super" (the old, broken
      # shape — see the 2026-08-09 handoff). No method-name constant
      # is involved: Op::Super carries only argc, since the name is
      # always read off the running frame at dispatch time.
      it "compiles `super()` to Op::Super with argc 0" do
        chunk = def_proc_chunk("class A\ndef foo\nend\nend\nclass B < A\ndef foo\nsuper()\nend\nend")
        inst = chunk.code.find { |i| i.op == Op::Super }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 0_u8
      end

      it "compiles `super(a, b)` to Op::Super with argc 2, args pushed first" do
        chunk = def_proc_chunk("class A\ndef foo(x, y)\nend\nend\nclass B < A\ndef foo(x, y)\nsuper(x, y)\nend\nend")
        idx = chunk.code.index { |i| i.op == Op::Super }
        idx.should_not be_nil
        chunk.code[idx.not_nil!].a.should eq 2_u8
      end

      it "compiles parenless `super a, b` the same as `super(a, b)`" do
        with_parens = def_proc_chunk("class A\ndef foo(x, y)\nend\nend\nclass B < A\ndef foo(x, y)\nsuper(x, y)\nend\nend")
        without_parens = def_proc_chunk("class A\ndef foo(x, y)\nend\nend\nclass B < A\ndef foo(x, y)\nsuper x, y\nend\nend")
        with_parens.code.map(&.op).should eq without_parens.code.map(&.op)
      end

      it "compiles bare `super` (no parens) with the zsuper flag bit set, argc 0" do
        chunk = def_proc_chunk("class A\ndef foo(x, y)\nend\nend\nclass B < A\ndef foo(x, y)\nsuper\nend\nend")
        inst = chunk.code.find { |i| i.op == Op::Super }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 0_u8
        (inst.not_nil!.b & 0b1_u16).should eq 1_u16
      end

      it "does NOT set the zsuper flag bit for explicit `super()`" do
        chunk = def_proc_chunk("class A\ndef foo\nend\nend\nclass B < A\ndef foo\nsuper()\nend\nend")
        inst = chunk.code.find { |i| i.op == Op::Super }
        inst.should_not be_nil
        (inst.not_nil!.b & 0b1_u16).should eq 0_u16
      end

      it "no longer emits Op::Call for `super`" do
        chunk = def_proc_chunk("class A\ndef foo\nend\nend\nclass B < A\ndef foo\nsuper()\nend\nend")
        chunk.code.map(&.op).should_not contain(Op::Call)
      end
    end
  end
end
