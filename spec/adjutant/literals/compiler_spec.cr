require "../../spec_helper"

module Adjutant
  describe Compiler do
    describe "literals" do
      it "compiles nil to Const" do
        chunk = compile("nil")
        chunk.code.first.op.should eq Op::Const
        chunk.consts.first.null?.should be_true
      end

      it "compiles true" do
        chunk = compile("true")
        chunk.consts.first.as_bool.should be_true
      end

      it "compiles false" do
        chunk = compile("false")
        chunk.consts.first.as_bool.should be_false
      end

      it "compiles an integer" do
        chunk = compile("42")
        chunk.consts.first.as_int.should eq 42_i64
      end

      it "compiles a negative NUMERIC LITERAL as a fused literal, not Unary+Neg" do
        # Changed 2026-07-25 (SCOPE.md's "Unary minus on a
        # NEGATIVE-NUMERIC-LITERAL binds looser than postfix" fix) —
        # `-7` immediately adjacent (no space) to a numeric literal now
        # fuses into a single negative IntLiteral at parse time
        # (parser.cr's parse_unary), matching Ruby's own tUMINUS_NUM
        # lexer-level mechanism, rather than compiling to a separate
        # Op::Neg over a positive constant. Same runtime value, simpler
        # bytecode (one Const, not Const+Neg) — and, more importantly,
        # this is what makes `-0.0.to_s` group as `(-0.0).to_s` instead
        # of `-(0.0.to_s)` (see the "does not compile Op::Neg" spec
        # right below, and operators/vm_spec.cr's coverage of the
        # actual to_s-grouping bug this was found from).
        chunk = compile("-7")
        chunk.code.map(&.op).should_not contain(Op::Neg)
        chunk.consts.first.as_int.should eq -7_i64
      end

      it "still compiles Unary+Neg for a non-literal unary-minus target" do
        # Every unary-minus target that ISN'T an immediately-adjacent
        # numeric literal — a variable, a call result, a parenthesized
        # expression, or even a literal WITH a space after the `-` —
        # is unaffected by the fusion above and still goes through the
        # ordinary Unary/Op::Neg path.
        chunk = compile("x = 7\n-x")
        chunk.code.map(&.op).should contain(Op::Neg)
      end

      it "compiles a hex integer" do
        chunk = compile("0xFF")
        chunk.consts.first.as_int.should eq 255_i64
      end

      it "compiles a float" do
        chunk = compile("3.14")
        chunk.consts.first.as_float.should be_close(3.14, 1e-10)
      end

      # Fixed 2026-07-25 (SCOPE.md's deferred underflow/overflow
      # sub-item, closed out). String#to_f64 raises ArgumentError on a
      # numerically out-of-Float64-range lexeme; mruby's own float
      # parser (and IEEE-754 generally) rounds these cleanly to a
      # signed 0.0/Infinity instead — confirmed as the correct target
      # behavior via mruby's own test/t/float.rb "Float literal
      # underflow" regression, which this closes.
      describe "underflow/overflow" do
        it "rounds an extreme negative-exponent literal to 0.0" do
          chunk = compile("1.0e-400")
          chunk.consts.first.as_float.should eq 0.0
        end

        it "rounds a large-mantissa extreme-exponent literal to signed -0.0" do
          # The actual case that most needed the TRUE combined exponent
          # (mantissa digit count + explicit e-suffix), not just the
          # e-suffix alone — a naive "just look at e-383" reading would
          # underestimate this literal's true magnitude by ~40 orders
          # of magnitude (41 mantissa digits).
          chunk = compile("-92170141183460469231731687303715884105729e-383")
          f = chunk.consts.first.as_float
          f.should eq 0.0
          (1.0 / f).should be < 0 # distinguishes -0.0 from 0.0
        end

        it "rounds an extreme positive-exponent literal to Infinity" do
          chunk = compile("1.0e400")
          chunk.consts.first.as_float.infinite?.should eq 1
        end

        it "rounds a negated extreme positive-exponent literal to -Infinity" do
          chunk = compile("-1.0e400")
          chunk.consts.first.as_float.infinite?.should eq -1
        end

        it "does not misjudge an all-zero mantissa with a huge exponent as overflow" do
          # A real bug found and fixed while implementing this: an
          # all-zero mantissa is mathematically 0 regardless of its
          # exponent (0 * 10^anything = 0), but the general true-
          # exponent calculation, if applied blindly, treats an
          # all-zero mantissa the same as a genuine leading-zero run
          # and computes a large POSITIVE exponent for "0.0e400" —
          # which would incorrectly route it to the overflow/Infinity
          # branch instead of leaving it as plain 0.0.
          chunk = compile("0.0e400")
          chunk.consts.first.as_float.should eq 0.0
          chunk.consts.first.as_float.infinite?.should be_nil
        end

        it "leaves an ordinary large-but-in-range literal untouched" do
          # From mruby's own float.rb test data directly — must NOT be
          # caught by the underflow/overflow guard just because it has
          # a big exponent; it's genuinely representable.
          chunk = compile("1.0e307")
          chunk.consts.first.as_float.should be_close(1.0e307, 1e300)
        end

        it "does not misclassify a near-boundary literal that the approximate exponent margin alone would miss" do
          # A second real edge case found while implementing this: the
          # exponent-range pre-check uses a deliberately approximate
          # margin (comfortably inside Float64's real ~308.25/-323.3
          # exponent bounds), NOT an exact boundary — so a literal with
          # true exponent 309 (genuinely over Float64::MAX) still falls
          # inside that approximate "safe" margin and must still be
          # caught via a to_f64? fallback within that branch, not just
          # the branch that's obviously out of range.
          chunk = compile("1.0e309")
          chunk.consts.first.as_float.infinite?.should eq 1
        end
      end

      it "compiles a string" do
        chunk = compile(%("hello"))
        chunk.consts.first.as_string.should eq "hello"
      end

      it "compiles a symbol" do
        chunk = compile(":ok")
        chunk.consts.first.as_sym.name.should eq "ok"
      end

      it "compiles an array literal" do
        ops("[1, 2, 3]").should contain(Op::MakeArray)
      end

      it "compiles a hash literal" do
        ops(%({ "a" => 1 })).should contain(Op::MakeHash)
      end

      it "compiles an inclusive range" do
        chunk = compile("1..10")
        chunk.code.map(&.op).should contain(Op::MakeRange)
        range_inst = chunk.code.find { |i| i.op == Op::MakeRange }.not_nil!
        range_inst.a.should eq 0_u8
      end

      it "compiles an exclusive range" do
        chunk = compile("1...10")
        range_inst = chunk.code.find { |i| i.op == Op::MakeRange }.not_nil!
        range_inst.a.should eq 1_u8
      end

      it "compiles an interpolated string" do
        ops(%("hello \#{42}!")).should contain(Op::Concat)
      end
    end

    describe "constant pool deduplication" do
      it "deduplicates nil constants" do
        chunk = compile("nil")
        chunk.consts.count { |v| v.null? }.should eq 1
      end

      it "deduplicates boolean constants" do
        chunk = compile("true")
        chunk.consts.count { |v| v.bool? && v.as_bool }.should eq 1
      end

      it "deduplicates symbol constants" do
        # x = 1; x used to exercise this by accident, via
        # SetGlobal/GetGlobal both needing a :x Sym constant to look
        # up in @globals — now that top-level locals get real
        # CompilerScope slots (see the 2026-07-15 scoping fix),
        # x = 1; x compiles to SetLocal/GetLocal (integer slot
        # indices, no Sym constant involved at all). Test what this
        # spec is actually about — Symbol constant dedup — directly,
        # with a repeated Symbol literal instead.
        chunk = compile(":x\n:x")
        x_count = chunk.consts.count { |v| v.symbol? && v.as_sym.name == "x" }
        x_count.should eq 1
      end
    end
  end
end
