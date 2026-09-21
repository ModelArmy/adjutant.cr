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
        l = RiskFlowLabel.of(ProvenanceKind::Host, "internal-db.corp.local")
        v = Value.int(1_i64, l)
        v.label.should eq l
      end

      it "attaches a label via with_label" do
        l = RiskFlowLabel.of(ProvenanceKind::File, "/tmp/scratch")
        v = Value.int(1_i64).with_label(l)
        v.label.should eq l
        v.as_int.should eq 1_i64
      end

      it "label propagates on copy (struct assignment)" do
        l = RiskFlowLabel.of(ProvenanceKind::UserInput, "stdin")
        a = Value.int(42_i64, l)
        b = a # struct copy
        b.label.should eq l
        b.as_int.should eq 42_i64
      end

      it "joins labels from two values into a union of tags" do
        la = RiskFlowLabel.of(ProvenanceKind::Host, "internal-db.corp.local")
        lb = RiskFlowLabel.of(ProvenanceKind::File, "/etc/hosts")
        a = Value.int(1_i64, la)
        b = Value.int(2_i64, lb)
        result = a.join_label(b)
        joined = result.label.not_nil!
        joined.tags.size.should eq 2
        joined.tags.should contain ProvenanceTag.new(ProvenanceKind::Host, "internal-db.corp.local")
        joined.tags.should contain ProvenanceTag.new(ProvenanceKind::File, "/etc/hosts")
      end

      it "join keeps the worse sensitivity when both sides tag the same origin" do
        la = RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::None)
        lb = RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High)
        joined = RiskFlowLabel.join(la, lb).not_nil!
        joined.tags.size.should eq 1
        joined.sensitivity.should eq Sensitivity::High
      end

      it "join with nil on either side returns the other side unchanged" do
        l = RiskFlowLabel.of(ProvenanceKind::Host, "example.com")
        RiskFlowLabel.join(nil, l).should eq l
        RiskFlowLabel.join(l, nil).should eq l
        RiskFlowLabel.join(nil, nil).should be_nil
      end

      it "label sensitivity reflects the worst tag present" do
        l = RiskFlowLabel.new(Set{
          ProvenanceTag.new(ProvenanceKind::File, "/etc/hosts", Sensitivity::None),
          ProvenanceTag.new(ProvenanceKind::File, "/etc/passwd", Sensitivity::High),
        })
        l.sensitivity.should eq Sensitivity::High
      end

      it "shows label in inspect output" do
        l = RiskFlowLabel.of(ProvenanceKind::Host, "example.com")
        v = Value.string("secret", l)
        v.inspect.should eq "\"secret\" [label:{host:example.com}]"
      end
    end

    describe "#to_plain / #to_plain?" do
      it "converts every scalar to its plain Crystal equivalent" do
        Value.nil_value.to_plain.should be_nil
        Value.bool(true).to_plain.should eq true
        Value.int(42).to_plain.should eq 42_i64
        Value.float(1.5).to_plain.should eq 1.5
        Value.string("hi").to_plain.should eq "hi"
      end

      it "converts a Sym to its name — no Symbol variant exists on the far side" do
        sym = SPEC_SYMBOLS.intern("status")
        Value.symbol(sym).to_plain.should eq "status"
      end

      it "converts an Array/Hash recursively, dropping the LabeledArray/LabeledHash wrapper" do
        arr = Value.new(LabeledArray.new([Value.int(1), Value.string("a")]), nil)
        arr.to_plain.should eq [1_i64, "a"] of PlainValue

        entries = {Value.string("count") => Value.int(3), Value.string("ok") => Value.bool(true)}
        h = Value.new(LabeledHash.new(entries), nil)
        h.to_plain.should eq({"count" => 3_i64, "ok" => true} of String => PlainValue)
      end

      it "accepts Symbol-keyed Hashes exactly like String-keyed ones, at any nesting depth" do
        sym_ok = SPEC_SYMBOLS.intern("ok")
        top_entries = {Value.symbol(sym_ok) => Value.bool(true)}
        top = Value.new(LabeledHash.new(top_entries), nil)
        top.to_plain.should eq({"ok" => true} of String => PlainValue)

        # Nested one level down — the case a real Ruby literal like
        # `{tags: ["a"], nested: {ok: true}}` hits, and the exact
        # shape `Legate.log`'s `fields` argument produces.
        sym_nested = SPEC_SYMBOLS.intern("nested")
        inner_entries = {Value.symbol(sym_ok) => Value.bool(true)}
        inner = Value.new(LabeledHash.new(inner_entries), nil)
        outer_entries = {Value.symbol(sym_nested) => inner}
        outer = Value.new(LabeledHash.new(outer_entries), nil)

        expected_inner = {"ok" => true} of String => PlainValue
        expected = {"nested" => expected_inner} of String => PlainValue
        outer.to_plain.should eq(expected)
      end

      it "raises ArgumentError for a Hash with a non-String key" do
        entries = {Value.int(1) => Value.string("a")}
        h = Value.new(LabeledHash.new(entries), nil)
        expect_raises(ArgumentError) { h.to_plain }
        h.to_plain?.should be_nil
      end

      it "raises ArgumentError for a RubyClass — no implicit #to_s (a ScriptProc/RubyObject behave the same; " \
         "see log_spec.cr's lambda test for that end-to-end, since hand-constructing a real ScriptProc needs a real Chunk)" do
        cls = Value.rclass(RubyClass.new("Widget", nil, is_module: false))
        expect_raises(ArgumentError) { cls.to_plain }
        cls.to_plain?.should be_nil
      end

      it "to_plain? is the nil-on-failure counterpart, matching as_int?/as_int's own pairing" do
        Value.string("ok").to_plain?.should eq "ok"
        entries = {Value.int(1) => Value.string("a")}
        Value.new(LabeledHash.new(entries), nil).to_plain?.should be_nil
      end

      it "bounds recursion — a Value nested well past PLAIN_MAX_DEPTH fails rather than overflowing the stack" do
        deep = Value.int(0)
        (Value::PLAIN_MAX_DEPTH + 10).times { deep = Value.new(LabeledArray.new([deep]), nil) }
        deep.to_plain?.should be_nil

        shallow = Value.int(0)
        5.times { shallow = Value.new(LabeledArray.new([shallow]), nil) }
        shallow.to_plain?.should_not be_nil
      end
    end
  end
end
