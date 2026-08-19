require "../../spec_helper"

module Adjutant
  # Range: a real RubyObject (@__min/@__max/@__exclusive ivars)
  # backing `1..5`/`1...5` literals (see Op::MakeRange in vm.cr),
  # replacing the earlier `[start, end, exclusive_flag]` LabeledArray
  # stand-in noted in research/IFC_DESIGN.md and the 2026-07-14
  # handoff. #each is implemented via #succ (see Integer#succ in
  # integer_spec.cr), matching real Ruby's own Range#each rather than
  # hardcoding "is this an Integer range" — any bound type with a
  # #succ and an orderable comparison (see NativeCallContext#compare)
  # works the same way.
  #
  # for-loop-over-a-Range integration (compile_for's `expr.each`
  # desugar) is covered in control_flow/vm_spec.cr's "for loop"
  # describe block, alongside the other for/while loop-construct
  # specs, not here — this file is about Range's own native methods
  # and #each in isolation, independent of any particular loop
  # construct driving it.
  describe "Range" do
    it "1..5.class is Range" do
      eval("(1..5).class == Range").truthy?.should be_true
    end

    it "1..5.is_a?(Range) is true" do
      eval("(1..5).is_a?(Range)").truthy?.should be_true
    end

    it "is not an Array" do
      eval("(1..5).is_a?(Array)").falsy?.should be_true
    end

    describe "#min / #max / #first / #last" do
      it "returns the range's bounds" do
        result = eval("[(2..7).min, (2..7).max, (2..7).first, (2..7).last]")
        result.as_array.map(&.as_int).should eq [2, 7, 2, 7]
      end

      # Confirmed against real Ruby's own C source first, not assumed
      # — three DIFFERENT RangeError messages for what looks like the
      # same underlying "nil bound" condition twice over (#max and
      # #last both fire on a nil END, but with distinct wording).
      it "#max raises RangeError (R027) on an endless range" do
        error = expect_raises(RuntimeError) { eval("(1..).max") }
        error.diagnostic.not_nil!.code.should eq("R027")
      end

      it "#last raises RangeError (R028) on an endless range, a different message than #max's" do
        error = expect_raises(RuntimeError) { eval("(1..).last") }
        error.diagnostic.not_nil!.code.should eq("R028")
      end

      it "#min raises RangeError (R029) on a beginless range" do
        error = expect_raises(RuntimeError) { eval("(..5).min") }
        error.diagnostic.not_nil!.code.should eq("R029")
      end

      it "#first does NOT raise on an endless range — there's always a real first value" do
        eval("(1..).first").as_int.should eq 1
      end

      it "#first raises RangeError (R030) on a beginless range, a different message than #min's" do
        error = expect_raises(RuntimeError) { eval("(..5).first") }
        error.diagnostic.not_nil!.code.should eq("R030")
      end

      describe "#first(n)" do
        it "returns an Array of the first n elements" do
          eval("(1..10).first(3)").as_array.map(&.as_int).should eq [1, 2, 3]
        end

        it "returns fewer than n elements when the range itself is shorter" do
          eval("(1..3).first(10)").as_array.map(&.as_int).should eq [1, 2, 3]
        end

        it "respects exclusivity, same as #each/#to_a" do
          eval("(1...3).first(10)").as_array.map(&.as_int).should eq [1, 2]
        end

        it "returns an empty Array for n == 0" do
          eval("(1..10).first(0)").as_array.should be_empty
        end

        it "works on an endless range — stops after n regardless of the (missing) upper bound" do
          eval("(1..).first(3)").as_array.map(&.as_int).should eq [1, 2, 3]
        end

        it "raises ArgumentError (R031) for a negative count, matching Array#first's own message" do
          error = expect_raises(RuntimeError) { eval("(1..10).first(-1)") }
          error.diagnostic.not_nil!.code.should eq("R031")
        end

        it "still raises RangeError (R030) on a beginless range, same as the no-argument form" do
          error = expect_raises(RuntimeError) { eval("(..5).first(3)") }
          error.diagnostic.not_nil!.code.should eq("R030")
        end
      end

      it "#begin/#end never raise regardless of a nil bound, unlike #first/#last/#min/#max" do
        result = eval("[(1..).begin, (1..).end, (..5).begin, (..5).end]")
        arr = result.as_array
        arr[0].as_int.should eq 1
        arr[1].null?.should be_true
        arr[2].null?.should be_true
        arr[3].as_int.should eq 5
      end
    end

    describe "#exclusive?" do
      it "is false for .." do
        eval("(1..5).exclusive?").as_bool.should be_false
      end

      it "is true for ..." do
        eval("(1...5).exclusive?").as_bool.should be_true
      end
    end

    describe "#to_s" do
      it "renders an inclusive range with .." do
        eval("(1..5).to_s").as_string.should eq "1..5"
      end

      it "renders an exclusive range with ..." do
        eval("(1...5).to_s").as_string.should eq "1...5"
      end

      # Step 5 of the to_s/inspect overridability work (see
      # object_spec.cr's own header comment and DEVELOPMENT.md for
      # the full plan). Previously each bound was rendered via raw
      # Crystal string interpolation (Value#to_s), not real dispatch
      # — so a custom bound type's own script-defined `to_s` override
      # wasn't respected. Every case below exercises that fix.
      it "a String bound renders UNQUOTED via to_s, matching real Ruby's own Range#to_s (each bound via its own to_s, not inspect)" do
        eval(%(("a".."c").to_s)).as_string.should eq "a..c"
      end

      it "a custom bound type's own `def to_s` override is respected, via real dispatch" do
        result = eval(<<-RUBY)
        class Bound
          def to_s
            "custom!"
          end
        end
        (Bound.new..5).to_s
        RUBY
        result.as_string.should eq "custom!..5"
      end

      # A nil bound — real syntax now (endless/beginless ranges, see
      # SCOPE.md), previously only reachable via Range.new(nil, x) —
      # is OMITTED entirely, matching real Ruby, not rendered as the
      # literal string "nil".
      it "omits a nil end bound entirely (endless range)" do
        eval("(1..).to_s").as_string.should eq "1.."
      end

      it "omits a nil start bound entirely (beginless range)" do
        eval("(..5).to_s").as_string.should eq "..5"
      end
    end

    describe "#inspect" do
      # Previously Range had no `inspect` at all — any implicit
      # render (`p`, a Range nested inside an Array/Hash's own
      # inspect) fell through to Object's generic `#<Range>`
      # fallback. See array_spec.cr's/hash_spec.cr's own Range-
      # nesting coverage for the container side of this fix; these
      # test Range#inspect directly.

      it "renders an inclusive range the same shape as to_s, for plain numeric bounds" do
        eval("(1..5).inspect").as_string.should eq "1..5"
      end

      it "renders an exclusive range with ..." do
        eval("(1...5).inspect").as_string.should eq "1...5"
      end

      it "a String bound renders QUOTED via inspect — the actual to_s/inspect distinction real Ruby has for Range, unlike Array/Hash's plain aliasing" do
        eval(%(("a".."c").inspect)).as_string.should eq %("a".."c")
      end

      it "a custom bound type's own `def inspect` override is respected, via real dispatch, independent of any to_s override it might also have" do
        result = eval(<<-RUBY)
        class Bound
          def to_s
            "custom to_s"
          end

          def inspect
            "custom inspect"
          end
        end
        (Bound.new..5).inspect
        RUBY
        result.as_string.should eq "custom inspect..5"
      end

      it "a plain object bound with no override renders via Object's own default #inspect (ivar-listing, from step 1)" do
        result = eval(<<-RUBY)
        class Bound
          def initialize
            @x = 1
          end
        end
        (Bound.new..5).inspect
        RUBY
        result.as_string.should eq "#<Bound @x=1>..5"
      end

      it "a Range nested inside an Array now renders correctly, via real dispatch, instead of the generic #<Range> fallback" do
        eval("[1..3].to_s").as_string.should eq "[1..3]"
      end

      it "a Range nested inside a Hash value now renders correctly too" do
        eval(%({"r" => 1..3}.to_s)).as_string.should eq %({"r" => 1..3})
      end

      it "omits a nil end bound entirely (endless range)" do
        eval("(1..).inspect").as_string.should eq "1.."
      end

      it "omits a nil start bound entirely (beginless range)" do
        eval("(..5).inspect").as_string.should eq "..5"
      end
    end

    describe "#include?" do
      it "true for a value within bounds" do
        eval("(1..5).include?(3)").truthy?.should be_true
      end

      it "true for the max bound when inclusive" do
        eval("(1..5).include?(5)").truthy?.should be_true
      end

      it "false for the max bound when exclusive" do
        eval("(1...5).include?(5)").falsy?.should be_true
      end

      it "false for a value below the min bound" do
        eval("(1..5).include?(0)").falsy?.should be_true
      end

      # A nil bound means "no constraint on this side" — see
      # range.cr's own comment on this. NOT independently confirmed
      # against real Ruby the way #each/#step/#to_a's nil-bound
      # behavior above was — see verify_range_include.rb in the
      # handoff; revisit if that comes back different.
      it "an endless range includes anything at or above its start" do
        eval("(1..).include?(1_000_000)").truthy?.should be_true
      end

      it "an endless range excludes anything below its start" do
        eval("(1..).include?(0)").falsy?.should be_true
      end

      it "a beginless range includes anything at or below its end" do
        eval("(..5).include?(-1_000_000)").truthy?.should be_true
      end

      it "a beginless range excludes anything above its end" do
        eval("(..5).include?(6)").falsy?.should be_true
      end
    end

    describe "#each" do
      it "yields every value, inclusive of max for .." do
        result = eval(<<-RUBY)
          seen = []
          (1..4).each { |n| seen << n }
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3, 4]
      end

      it "excludes max for ..." do
        result = eval(<<-RUBY)
          seen = []
          (1...4).each { |n| seen << n }
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3]
      end

      it "yields nothing when min > max" do
        result = eval(<<-RUBY)
          seen = []
          (5..1).each { |n| seen << n }
          seen
        RUBY
        result.as_array.should be_empty
      end

      it "returns the receiver, matching real Ruby" do
        result = eval(<<-RUBY)
          r = 1..3
          (r.each { |n| n }).equal?(r)
        RUBY
        result.as_bool.should be_true
      end

      it "with no block, does not raise, and returns the receiver" do
        result = eval("(1..3).each")
        result.as_robject.rclass.name.should eq "Range"
      end

      # Nil-bound handling — confirmed against real Ruby via `irb`
      # first (see the handoff for the verification script), not
      # assumed: a nil END walks forever (the caller `break`s); a nil
      # START raises TypeError, since there's nothing to begin at.
      #
      # Was `pending` (see git history) — `break` inside a block
      # passed to a NATIVE method didn't actually stop the native
      # Crystal loop driving it, so this genuinely hung the VM rather
      # than just failing. Fixed via BlockBreakSignal (vm.cr) — see
      # SCOPE.md's now-resolved entry for the full mechanism.
      it "an endless range walks forever — the caller is expected to break" do
        result = eval(<<-RUBY)
          seen = []
          (1..).each do |n|
            if n > 4
              break
            end
            seen << n
          end
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3, 4]
      end

      it "a beginless range raises TypeError (R024), matching real Ruby's own message" do
        error = expect_raises(RuntimeError) { eval("(..5).each { |n| n }") }
        error.diagnostic.not_nil!.code.should eq("R024")
      end
    end

    it "every builtin Range method defaults to RiskProfile.none" do
      interp, _ = make_interp
      cls = interp.get_global("Range").as_rclass
      %w[min max first last exclusive? to_s include? each].each do |name|
        sym_id = interp.symbols.lookup(name).not_nil!.value
        cls.find_native_method(sym_id).not_nil!.risk.should eq RiskProfile.none
      end
    end

    it "is a real RubyObject, not an Array" do
      interp, _ = make_interp
      src = <<-RUBY
      r = 1..5
      [r.class.to_s, r.is_a?(Array)]
      RUBY
      result = interp.eval(src).as_array
      result[0].as_string.should eq "Range"
      result[1].as_bool.should be_false
    end

    it "exposes min/max/first/last" do
      src = <<-RUBY
      r = 2..7
      [r.min, r.max, r.first, r.last]
      RUBY
      result = eval(src).as_array.map(&.as_int)
      result.should eq [2, 7, 2, 7]
    end

    it "exclusive? is false for .. and true for ..." do
      src = <<-RUBY
      [(1..5).exclusive?, (1...5).exclusive?]
      RUBY
      result = eval(src).as_array.map(&.as_bool)
      result.should eq [false, true]
    end

    it "Integer#succ advances by one" do
      eval("5.succ").as_int.should eq 6
    end

    it "each yields every value, inclusive of max for .." do
      src = <<-RUBY
      seen = []
      (1..4).each { |n| seen << n }
      seen
      RUBY
      eval(src).as_array.map(&.as_int).should eq [1, 2, 3, 4]
    end

    it "each excludes max for ..." do
      src = <<-RUBY
      seen = []
      (1...4).each { |n| seen << n }
      seen
      RUBY
      eval(src).as_array.map(&.as_int).should eq [1, 2, 3]
    end

    it "each on an empty range (min > max) yields nothing" do
      src = <<-RUBY
      seen = []
      (5..1).each { |n| seen << n }
      seen
      RUBY
      eval(src).as_array.should be_empty
    end

    it "each returns the receiver, matching real Ruby" do
      src = <<-RUBY
      r = 1..3
      (r.each { |n| n }).equal?(r)
      RUBY
      eval(src).as_bool.should be_true
    end

    it "include? respects exclusivity at the boundary" do
      src = <<-RUBY
      [
        (1..5).include?(5),
        (1...5).include?(5),
        (1..5).include?(0),
        (1..5).include?(3),
      ]
      RUBY
      result = eval(src).as_array.map(&.as_bool)
      result.should eq [true, false, false, true]
    end

    describe "#to_a" do
      it "materializes an inclusive range" do
        eval("(1..5).to_a").as_array.map(&.as_int).should eq [1, 2, 3, 4, 5]
      end

      it "materializes an exclusive range" do
        eval("(1...5).to_a").as_array.map(&.as_int).should eq [1, 2, 3, 4]
      end

      it "an empty (backward) range materializes to an empty array" do
        eval("(5..1).to_a").as_array.empty?.should be_true
      end

      it "carries the receiver's own label forward" do
        interp, _ = make_interp
        plain_range = interp.eval("1..3")
        labeled_range = plain_range.with_label(RiskFlowLabel.of(ProvenanceKind::File, "/etc/passwd", Sensitivity::High))
        interp.define_native("tainted_range") do |args|
          labeled_range
        end
        result = interp.eval("tainted_range.to_a")
        result.label.should_not be_nil
      end

      # Nil-bound handling, confirmed against real Ruby first: #to_a
      # has no `break` escape hatch the way #each does, so a nil END
      # can't just walk forever here — it raises RangeError instead.
      # A nil START still raises TypeError, same reason as #each.
      it "an endless range raises RangeError (R026), matching real Ruby's own message" do
        error = expect_raises(RuntimeError) { eval("(1..).to_a") }
        error.diagnostic.not_nil!.code.should eq("R026")
      end

      it "a beginless range raises TypeError (R024)" do
        error = expect_raises(RuntimeError) { eval("(..5).to_a") }
        error.diagnostic.not_nil!.code.should eq("R024")
      end
    end

    describe "#step" do
      it "yields values stepped by n, matching real Ruby" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          seen = []
          (1..10).step(3) { |n| seen << n }
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 4, 7, 10]
      end

      it "respects exclusivity" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          seen = []
          (1...10).step(3) { |n| seen << n }
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 4, 7]
      end

      it "defaults to a step of 1 when omitted" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          seen = []
          (1..3).step { |n| seen << n }
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 2, 3]
      end

      it "returns the receiver" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          r = 1..3
          (r.step(1) { |n| n }).equal?(r)
        RUBY
        result.as_bool.should be_true
      end

      it "with no block, does not raise, and returns the receiver" do
        interp, _ = make_interp
        result = interp.eval("(1..3).step(1)")
        result.truthy?.should be_true
      end

      it "raises ArgumentError (R020) for a step of 0" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("(1..3).step(0) { |n| n }") }
        error.diagnostic.not_nil!.code.should eq("R020")
      end

      it "the ArgumentError is rescuable from script" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          begin
            (1..3).step(0) { |n| n }
            false
          rescue ArgumentError
            true
          end
        RUBY
        result.as_bool.should be_true
      end

      # Nil-bound handling, confirmed against real Ruby first: a nil
      # END walks forever, same as #each. A nil START raises
      # ArgumentError (R025) — a DIFFERENT error class than #each's
      # TypeError (R024) for the same nil-start situation; real Ruby
      # genuinely picks a different class here, not a typo.
      #
      # Was `pending` (see git history and #each's identical spec
      # above) — fixed via BlockBreakSignal (vm.cr).
      it "an endless range walks forever — the caller is expected to break" do
        interp, _ = make_interp
        result = interp.eval(<<-RUBY)
          seen = []
          (1..).step(3) do |n|
            if seen.size == 3
              break
            end
            seen << n
          end
          seen
        RUBY
        result.as_array.map(&.as_int).should eq [1, 4, 7]
      end

      it "a beginless range raises ArgumentError (R025), a different class than #each's TypeError" do
        interp, _ = make_interp
        error = expect_raises(RuntimeError) { interp.eval("(..5).step(1) { |n| n }") }
        error.diagnostic.not_nil!.code.should eq("R025")
      end
    end

    describe "#==" do
      it "two ranges with the same bounds and exclusivity are equal" do
        interp, _ = make_interp
        result = interp.eval("(1..10) == (1..10)")
        result.truthy?.should be_true
      end

      it "different max values are not equal" do
        interp, _ = make_interp
        result = interp.eval("(1..10) == (1..100)")
        result.truthy?.should be_false
      end

      it "same bounds but different exclusivity are not equal" do
        interp, _ = make_interp
        result = interp.eval("(1..10) == (1...10)")
        result.truthy?.should be_false
      end
    end

    describe "Range.new" do
      it "constructs an inclusive range equivalent to literal syntax" do
        interp, _ = make_interp
        result = interp.eval("Range.new(1, 10) == (1..10)")
        result.truthy?.should be_true
      end

      it "constructs an exclusive range when the third argument is truthy" do
        interp, _ = make_interp
        result = interp.eval("Range.new(1, 10, true) == (1...10)")
        result.truthy?.should be_true
      end

      it "works with each/to_a like literal syntax" do
        interp, _ = make_interp
        result = interp.eval("Range.new(1, 5).to_a")
        result.as_array.map(&.as_int).should eq [1, 2, 3, 4, 5]
      end
    end

    describe "#begin / #end" do
      it "begin returns the same value as #first" do
        interp, _ = make_interp
        result = interp.eval("(1..10).begin")
        result.as_int.should eq 1
      end

      it "end returns the same value as #last" do
        interp, _ = make_interp
        result = interp.eval("(1..10).end")
        result.as_int.should eq 10
      end
    end

    describe "#exclude_end? / #member?" do
      it "exclude_end? matches exclusivity, same as #exclusive?" do
        interp, _ = make_interp
        interp.eval("(1...10).exclude_end?").truthy?.should be_true
        interp.eval("(1..10).exclude_end?").truthy?.should be_false
      end

      it "member? is an alias for include?" do
        interp, _ = make_interp
        interp.eval("(1..10).member?(5)").truthy?.should be_true
        interp.eval("(1..10).member?(20)").truthy?.should be_false
      end
    end
  end
end
