require "../../spec_helper"

module Adjutant
  describe Parser do
    describe "include (Step 1 — parses as an ordinary bare method call)" do
      # `include` was a reserved keyword with zero parser handling
      # (P002, unexpected token) — removed 2026-08-10 (see token.cr's
      # own comment) since it needs no special grammar at all: real
      # Ruby's `include` is an ordinary Module method, not a keyword,
      # and `include Foo` is indistinguishable in shape from any other
      # bare call taking one argument.

      it "parses `include Foo` as an ordinary Call with Foo as its argument" do
        node = parse_expr("include Foo").as(Call)
        node.method.should eq "include"
        node.receiver.should be_nil
        node.args.size.should eq 1
        node.args.first.as(Constant).name.should eq "Foo"
      end

      it "parses inside a class body, same as any other bare statement there" do
        node = parse_expr("class A\ninclude Foo\nend").as(ClassNode)
        call = node.body.stmts.first.as(Call)
        call.method.should eq "include"
        call.args.first.as(Constant).name.should eq "Foo"
      end

      it "parses inside a module body" do
        node = parse_expr("module M\ninclude Foo\nend").as(ModuleNode)
        call = node.body.stmts.first.as(Call)
        call.method.should eq "include"
        call.args.first.as(Constant).name.should eq "Foo"
      end

      it "parses multiple includes in source order, preserved as separate statements" do
        node = parse_expr("class A\ninclude Foo\ninclude Bar\nend").as(ClassNode)
        node.body.stmts.size.should eq 2
        node.body.stmts[0].as(Call).args.first.as(Constant).name.should eq "Foo"
        node.body.stmts[1].as(Call).args.first.as(Constant).name.should eq "Bar"
      end

      it "parses a namespaced module argument (A::B) via the ordinary ConstPath path" do
        node = parse_expr("include A::B").as(Call)
        node.args.first.should be_a(ConstPath)
      end

      it "`include` still works as an ordinary local variable/method name elsewhere (no longer reserved)" do
        # Confirms the keyword removal didn't just relocate the
        # restriction — `include` is now a fully ordinary identifier,
        # usable as a ScriptModule method name, ivar-free local, etc.
        node = parse_expr("include = 5").as(Assign)
        node.target.as(Identifier).name.should eq "include"
      end
    end

    describe "extend (Step 2 — parses as an ordinary bare method call, mirroring include's own Step 1)" do
      # Same reasoning as include's own describe block above —
      # `extend` was a reserved keyword with zero parser handling,
      # removed 2026-08-10 once `extend` itself was actually built
      # (see token.cr's own comment).

      it "parses `extend Foo` as an ordinary Call with Foo as its argument" do
        node = parse_expr("extend Foo").as(Call)
        node.method.should eq "extend"
        node.receiver.should be_nil
        node.args.size.should eq 1
        node.args.first.as(Constant).name.should eq "Foo"
      end

      it "parses inside a class body" do
        node = parse_expr("class A\nextend Foo\nend").as(ClassNode)
        call = node.body.stmts.first.as(Call)
        call.method.should eq "extend"
        call.args.first.as(Constant).name.should eq "Foo"
      end

      it "parses a namespaced module argument (A::B) via the ordinary ConstPath path" do
        node = parse_expr("extend A::B").as(Call)
        node.args.first.should be_a(ConstPath)
      end

      it "`extend` still works as an ordinary local variable/method name elsewhere (no longer reserved)" do
        node = parse_expr("extend = 5").as(Assign)
        node.target.as(Identifier).name.should eq "extend"
      end
    end
  end
end
