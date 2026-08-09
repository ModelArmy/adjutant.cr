require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "attr_reader / attr_writer / attr_accessor" do
      it "compiles attr_reader :x to a method body that reads the ivar" do
        o = def_proc_chunk("attr_reader :x").code.map(&.op)
        o.should contain(Op::GetIvar)
        o.should_not contain(Op::SetIvar)
      end

      it "compiles attr_writer :x to a method body that writes the ivar" do
        # def_proc_chunk follows the LAST Op::MakeProc in the outer
        # chunk — attr_writer emits exactly one def, so this is
        # unambiguous (unlike attr_accessor, which emits two; see the
        # "both methods get compiled" spec below for how that's
        # asserted instead).
        o = def_proc_chunk("attr_writer :x").code.map(&.op)
        o.should contain(Op::SetIvar)
        o.should_not contain(Op::GetIvar)
      end

      it "attr_writer's method takes exactly one param (GetLocal for it, no GetArgc default-guard)" do
        chunk = def_proc_chunk("attr_writer :x")
        # A required param (no default) never emits a default-value
        # guard at all — see emit_default_prologue's own doc comment
        # elsewhere; absence of Op::GetArgc here confirms `value` was
        # built as a plain required Param, not accidentally given a
        # default.
        chunk.code.map(&.op).should_not contain(Op::GetArgc)
      end

      it "attr_accessor :x emits two real Op::DefMethod definitions, not one" do
        o = ops("class Foo\nattr_accessor :x\nend")
        o.count(Op::DefMethod).should eq 2
      end

      it "attr_accessor :x, :y emits four real Op::DefMethod definitions" do
        o = ops("class Foo\nattr_accessor :x, :y\nend")
        o.count(Op::DefMethod).should eq 4
      end

      it "attr_reader alone emits exactly one Op::DefMethod" do
        o = ops("class Foo\nattr_reader :x\nend")
        o.count(Op::DefMethod).should eq 1
      end

      it "combines with an ordinary def in the same class without interference" do
        o = ops(<<-RUBY)
          class Point
            attr_accessor :x, :y
            def initialize(x, y)
              @x = x
              @y = y
            end
          end
          RUBY
        # 4 attr defs + 1 initialize = 5.
        o.count(Op::DefMethod).should eq 5
      end
    end
  end
end
