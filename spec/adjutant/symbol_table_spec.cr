require "../spec_helper"

module Adjutant
  describe Sym do
    it "holds a value and name" do
      s = Sym.new(0, "foo")
      s.value.should eq 0
      s.name.should eq "foo"
    end

    it "compares by integer value" do
      a = Sym.new(1, "foo")
      b = Sym.new(1, "foo")
      c = Sym.new(2, "bar")
      (a == b).should be_true
      (a == c).should be_false
    end

    it "renders with leading colon" do
      Sym.new(0, "ok").to_s.should eq ":ok"
    end
  end

  describe SymbolTable do
    it "interns a symbol and returns a Sym" do
      table = SymbolTable.new
      s = table.intern("foo")
      s.should be_a(Sym)
      s.name.should eq "foo"
    end

    it "returns the same Sym for the same name" do
      table = SymbolTable.new
      a = table.intern("foo")
      b = table.intern("foo")
      a.value.should eq b.value
    end

    it "assigns different IDs to different names" do
      table = SymbolTable.new
      a = table.intern("foo")
      b = table.intern("bar")
      a.value.should_not eq b.value
    end

    it "assigns sequential IDs" do
      table = SymbolTable.new
      a = table.intern("first")
      b = table.intern("second")
      b.value.should eq a.value + 1
    end

    it "looks up an existing symbol without interning" do
      table = SymbolTable.new
      table.intern("foo")
      s = table.lookup("foo")
      s.should_not be_nil
      s.not_nil!.name.should eq "foo"
    end

    it "returns nil for unknown symbol on lookup" do
      table = SymbolTable.new
      table.lookup("unknown").should be_nil
    end

    it "tracks size correctly" do
      table = SymbolTable.new
      table.intern("a")
      table.intern("b")
      table.intern("a") # duplicate
      table.size.should eq 2
    end

    it "is isolated between instances" do
      t1 = SymbolTable.new
      t2 = SymbolTable.new
      s1 = t1.intern("foo")
      s2 = t2.intern("foo")
      # Same name, same first ID (both start at 0), but independent tables
      s1.value.should eq s2.value
      s1.name.should eq s2.name
    end

    it "supports symbol comparison via Value" do
      table = SymbolTable.new
      v1 = Value.symbol(table.intern("ok"))
      v2 = Value.symbol(table.intern("ok"))
      v3 = Value.symbol(table.intern("err"))
      v1.as_sym.should eq v2.as_sym
      (v1.as_sym == v3.as_sym).should be_false
    end

    it "shared table ensures cross-compilation symbol identity" do
      table = SymbolTable.new
      # Simulate two scripts compiled against the same interpreter
      body1 = Parser.new(":shared").parse
      body2 = Parser.new(":shared").parse
      chunk1, _lc1 = Compiler.compile(body1, table)
      chunk2, _lc2 = Compiler.compile(body2, table)
      sym1 = chunk1.consts.find(&.symbol?).not_nil!.as_sym
      sym2 = chunk2.consts.find(&.symbol?).not_nil!.as_sym
      sym1.value.should eq sym2.value
    end
  end
end
