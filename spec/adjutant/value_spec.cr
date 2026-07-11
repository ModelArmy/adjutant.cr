require "../spec_helper"

module Adjutant
  # Shared symbol table for value specs
  SPEC_SYMBOLS = SymbolTable.new

  describe Value do
    describe "nil value" do
      it "has Nil tag" do
        Value.nil_value.null?.should be_true
      end

      it "is null?" do
        Value.nil_value.null?.should be_true
      end

      it "is falsy" do
        Value.nil_value.truthy?.should be_false
      end

      it "to_s is the empty string — matches real Ruby's nil.to_s" do
        Value.nil_value.to_s.should eq ""
      end

      it "inspect still renders as \"nil\"" do
        Value.nil_value.inspect.should eq "nil"
      end
    end

    describe "bool values" do
      it "stores true" do
        v = Value.bool(true)
        v.bool?.should be_true
        v.as_bool.should be_true
        v.truthy?.should be_true
      end

      it "stores false" do
        v = Value.bool(false)
        v.as_bool.should be_false
        v.truthy?.should be_false
      end

      it "renders correctly" do
        Value.bool(true).to_s.should eq "true"
        Value.bool(false).to_s.should eq "false"
      end
    end

    describe "int values" do
      it "stores an integer" do
        v = Value.int(42_i64)
        v.int?.should be_true
        v.as_int.should eq 42_i64
        v.truthy?.should be_true
      end

      it "stores negative integers" do
        Value.int(-7_i64).as_int.should eq -7_i64
      end

      it "renders correctly" do
        Value.int(99_i64).to_s.should eq "99"
      end
    end

    describe "float values" do
      it "stores a float" do
        v = Value.float(3.14)
        v.float?.should be_true
        v.as_float.should be_close(3.14, 1e-10)
        v.truthy?.should be_true
      end

      it "renders correctly" do
        Value.float(1.5).to_s.should eq "1.5"
      end
    end

    describe "string values" do
      it "stores a string" do
        v = Value.string("hello")
        v.string?.should be_true
        v.as_string.should eq "hello"
        v.truthy?.should be_true
      end

      it "renders without quotes via to_s" do
        Value.string("hello").to_s.should eq "hello"
      end

      it "renders with quotes via inspect" do
        Value.string("hello").inspect.should eq "\"hello\""
      end
    end

    describe "symbol values" do
      it "stores a symbol" do
        v = Value.symbol(SPEC_SYMBOLS.intern("ok"))
        v.symbol?.should be_true
        v.as_sym.name.should eq "ok"
        v.truthy?.should be_true
      end

      it "renders with colon prefix" do
        Value.symbol(SPEC_SYMBOLS.intern("name")).to_s.should eq ":name"
      end

      it "renders with colon prefix via inspect" do
        Value.symbol(SPEC_SYMBOLS.intern("name")).inspect.should eq ":name"
      end
    end

    describe "IFC label handling" do
      it "has no label by default" do
        Value.int(1_i64).label.should be_nil
      end

      it "carries a label when constructed with one" do
        l = SecurityLabel.of(ProvenanceKind::Network, "internal-db.corp.local")
        v = Value.int(1_i64, l)
        v.label.should eq l
      end

      it "attaches a label via with_label" do
        l = SecurityLabel.of(ProvenanceKind::File, "/tmp/scratch")
        v = Value.int(1_i64).with_label(l)
        v.label.should eq l
        v.as_int.should eq 1_i64
      end

      it "label propagates on copy (struct assignment)" do
        l = SecurityLabel.of(ProvenanceKind::UserInput, "stdin")
        a = Value.int(42_i64, l)
        b = a # struct copy
        b.label.should eq l
        b.as_int.should eq 42_i64
      end

      it "joins labels from two values into a union of tags" do
        la = SecurityLabel.of(ProvenanceKind::Network, "internal-db.corp.local")
        lb = SecurityLabel.of(ProvenanceKind::File, "/etc/hosts")
        a = Value.int(1_i64, la)
        b = Value.int(2_i64, lb)
        result = a.join_label(b)
        joined = result.label.not_nil!
        joined.tags.size.should eq 2
        joined.tags.should contain ProvenanceTag.new(ProvenanceKind::Network, "internal-db.corp.local")
        joined.tags.should contain ProvenanceTag.new(ProvenanceKind::File, "/etc/hosts")
      end

      it "join keeps the worse sensitivity when both sides tag the same origin" do
        la = SecurityLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::None)
        lb = SecurityLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
        joined = SecurityLabel.join(la, lb).not_nil!
        joined.tags.size.should eq 1
        joined.sensitivity.should eq Sensitivity::High
      end

      it "join with nil on either side returns the other side unchanged" do
        l = SecurityLabel.of(ProvenanceKind::Network, "example.com")
        SecurityLabel.join(nil, l).should eq l
        SecurityLabel.join(l, nil).should eq l
        SecurityLabel.join(nil, nil).should be_nil
      end

      it "label sensitivity reflects the worst tag present" do
        l = SecurityLabel.new(Set{
          ProvenanceTag.new(ProvenanceKind::File, "/etc/hosts", Sensitivity::None),
          ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::High),
        })
        l.sensitivity.should eq Sensitivity::High
      end

      it "shows label in inspect output" do
        l = SecurityLabel.of(ProvenanceKind::Network, "example.com")
        v = Value.string("secret", l)
        v.inspect.should eq "\"secret\" [label:{network:example.com}]"
      end
    end
  end
end
