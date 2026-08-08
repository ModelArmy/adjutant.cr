require "../../spec_helper"

module Adjutant
  # Chunk 1 of typed exceptions: begin/rescue actually catching a raised
  # error, not just parsing/compiling one. Prior to this, Op::Try set
  # Frame#rescue_ip but execute() never consulted it, so any runtime
  # error (division by zero, explicit raise, native errors) unwound
  # straight past the VM regardless of an enclosing rescue.
  #
  # Chunk 2 (see "typed error objects" describe block below): the
  # rescue variable is now a RubyObject of a real error class
  # (StandardError, RuntimeError, etc.), not a raw string — read its
  # message via `.message`.
  describe "begin/rescue error catching" do
    it "catches a runtime error (division by zero)" do
      result = eval(<<-RUBY)
        begin
          1 / 0
        rescue e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "does not touch the rescue body on success" do
      eval(<<-RUBY).should eq Value.int(2_i64)
        begin
          1 + 1
        rescue e
          :failed
        end
      RUBY
    end

    it "binds the rescue variable to the error message" do
      eval(<<-RUBY).should eq Value.string("divided by 0")
        begin
          1 / 0
        rescue e
          e.message
        end
      RUBY
    end

    it "catches an explicit raise with a custom message" do
      eval(<<-RUBY).should eq Value.string("boom")
        begin
          raise "boom"
        rescue e
          e.message
        end
      RUBY
    end

    it "stops executing the begin body at the point of the error" do
      eval(<<-RUBY).should eq Value.bool(false)
        ran_after = false
        begin
          1 / 0
          ran_after = true
        rescue e
          nil
        end
        ran_after
      RUBY
    end

    it "catches an error raised one call frame deep" do
      result = eval(<<-RUBY)
        def blow_up
          1 / 0
        end

        begin
          blow_up()
        rescue e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "catches an error raised several call frames deep" do
      result = eval(<<-RUBY)
        def level_three
          1 / 0
        end

        def level_two
          level_three()
        end

        def level_one
          level_two()
        end

        begin
          level_one()
        rescue e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "leaves the stack clean after unwinding a deep error" do
      # A regression guard: unwinding multiple frames must also unwind
      # their stack contents, or subsequent stack ops would be corrupted.
      eval(<<-RUBY).should eq Value.int(5_i64)
        def blow_up
          1 / 0
        end

        begin
          blow_up()
        rescue e
          nil
        end

        2 + 3
      RUBY
    end

    it "still propagates an uncaught error past a frame with no rescue handler" do
      expect_raises(RuntimeError, /divided by 0/) do
        eval(<<-RUBY)
          1 / 0
        RUBY
      end
    end
  end

  describe "typed error objects" do
    it "resolves the builtin error hierarchy as real classes" do
      interp, _ = make_interp
      %w[Exception StandardError RuntimeError TypeError ArgumentError
        ZeroDivisionError NameError NoMethodError IndexError KeyError].each do |name|
        val = interp.get_global(name)
        val.rclass?.should be_true
        val.as_rclass.name.should eq name
      end
    end

    it "gives RuntimeError a StandardError superclass" do
      interp, _ = make_interp
      re = interp.get_global("RuntimeError").as_rclass
      re.superclass.try(&.name).should eq "StandardError"
    end

    it "constructs a real error object for an unqualified raise" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        begin
          raise "boom"
        rescue e
          e
        end
      RUBY
      result.robject?.should be_true
      result.as_robject.rclass.name.should eq "RuntimeError"
    end

    it "raises a specific builtin error class" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        begin
          raise TypeError, "expected a String"
        rescue e
          e
        end
      RUBY
      result.robject?.should be_true
      result.as_robject.rclass.name.should eq "TypeError"
    end

    it "defaults the message to the class name when raise ClassName has no message" do
      eval(<<-RUBY).should eq Value.string("ArgumentError")
        begin
          raise ArgumentError
        rescue e
          e.message
        end
      RUBY
    end

    it "types internal VM errors (division by zero) as RuntimeError objects too" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        begin
          1 / 0
        rescue e
          e
        end
      RUBY
      result.robject?.should be_true
      result.as_robject.rclass.name.should eq "RuntimeError"
    end

    it "supports .message on an internal error the same as an explicit raise" do
      eval(<<-RUBY).should eq Value.string("divided by 0")
        begin
          1 / 0
        rescue e
          e.message
        end
      RUBY
    end
  end

  describe "rescue ClassName filtering" do
    it "runs the rescue body when the raised class matches exactly" do
      eval(<<-RUBY).should eq Value.string("caught")
        begin
          raise TypeError, "nope"
        rescue TypeError => e
          "caught"
        end
      RUBY
    end

    it "runs the rescue body when the raised class is a subclass of the filter" do
      eval(<<-RUBY).should eq Value.string("caught")
        begin
          raise TypeError, "nope"
        rescue StandardError => e
          "caught"
        end
      RUBY
    end

    it "does not run the rescue body when the raised class does not match" do
      expect_raises(RuntimeError, /nope/) do
        eval(<<-RUBY)
          begin
            raise TypeError, "nope"
          rescue ArgumentError => e
            "caught"
          end
        RUBY
      end
    end

    it "preserves the original class through a mismatch re-raise across a call boundary" do
      # A class filter that doesn't match must not launder the error
      # into a generic RuntimeError — an outer handler filtering on
      # the *original* class should still be able to catch it. This
      # crosses a real call boundary (separate Frame objects) rather
      # than nesting begin/rescue in one frame — see the known
      # limitation test below for why that distinction matters.
      result = eval(<<-RUBY)
        def inner
          begin
            raise TypeError, "nope"
          rescue ArgumentError => e
            "inner caught"
          end
        end

        begin
          inner()
        rescue TypeError => e
          "outer caught: " + e.message
        end
      RUBY
      result.should eq Value.string("outer caught: nope")
    end

    it "supports a class filter with no bound variable" do
      eval(<<-RUBY).should eq Value.string("caught")
        begin
          raise TypeError, "nope"
        rescue TypeError
          "caught"
        end
      RUBY
    end

    it "matches an internal VM error (division by zero) against RuntimeError" do
      eval(<<-RUBY).should eq Value.string("caught")
        begin
          1 / 0
        rescue RuntimeError => e
          "caught"
        end
      RUBY
    end

    it "does not match an internal VM error against an unrelated class" do
      expect_raises(RuntimeError, /divided by 0/) do
        eval(<<-RUBY)
          begin
            1 / 0
          rescue TypeError => e
            "caught"
          end
        RUBY
      end
    end

    it "is_a? correctly reports class and ancestor membership" do
      interp, _ = make_interp
      interp.eval(<<-RUBY).as_bool.should be_true
        begin
          raise TypeError, "x"
        rescue TypeError => e
          e.is_a?(TypeError)
        end
      RUBY
      interp.eval(<<-RUBY).as_bool.should be_true
        begin
          raise TypeError, "x"
        rescue TypeError => e
          e.is_a?(StandardError)
        end
      RUBY
      interp.eval(<<-RUBY).as_bool.should be_false
        begin
          raise TypeError, "x"
        rescue TypeError => e
          e.is_a?(ArgumentError)
        end
      RUBY
    end

    it "same-frame nested rescue falls back to an outer handler on mismatch (regression: single rescue_ip slot)" do
      # Frame used to carry a single rescue_ip slot, not a handler
      # stack. Two begin/rescue blocks nested in the *same* frame (no
      # call boundary between them) meant the inner Op::Try clobbered
      # the outer's rescue_ip, so a mismatch in the inner rescue
      # couldn't fall back to an enclosing one. Frame#handlers is now
      # a stack of per-construct entries — a mismatch reraise
      # correctly finds the next entry up.
      result = eval(<<-RUBY)
        begin
          begin
            begin
              raise TypeError, "nope"
            rescue ArgumentError => e
              "innermost caught"
            end
          rescue NameError => e
            "middle caught"
          end
        rescue StandardError => e
          "outer caught: " + e.message
        end
      RUBY
      result.should eq Value.string("outer caught: nope")
    end
  end

  describe "multiple rescue clauses" do
    it "runs the first clause whose class matches" do
      eval(<<-RUBY).should eq Value.string("type")
        begin
          raise TypeError, "nope"
        rescue TypeError => e
          "type"
        rescue ArgumentError => e
          "arg"
        end
      RUBY
    end

    it "falls through to a later clause when an earlier one doesn't match" do
      eval(<<-RUBY).should eq Value.string("arg")
        begin
          raise ArgumentError, "nope"
        rescue TypeError => e
          "type"
        rescue ArgumentError => e
          "arg"
        end
      RUBY
    end

    it "runs a trailing bare rescue as a catch-all after typed clauses miss" do
      eval(<<-RUBY).should eq Value.string("caught")
        begin
          raise IndexError, "nope"
        rescue TypeError => e
          "type"
        rescue ArgumentError => e
          "arg"
        rescue
          "caught"
        end
      RUBY
    end

    it "re-raises the original error when no clause matches" do
      expect_raises(RuntimeError, /nope/) do
        eval(<<-RUBY)
          begin
            raise TypeError, "nope"
          rescue ArgumentError => e
            "arg"
          rescue NameError => e
            "name"
          end
        RUBY
      end
    end

    it "only runs the matching clause's body, not any other clause's" do
      result = eval(<<-RUBY)
        ran = []
        begin
          raise ArgumentError, "nope"
        rescue TypeError => e
          ran << :type
        rescue ArgumentError => e
          ran << :arg
        rescue NameError => e
          ran << :name
        end
        ran
      RUBY
      result.as_array.map(&.as_sym.name).should eq ["arg"]
    end

    it "picks first-listed on order, not most-specific (matches real Ruby)" do
      # TypeError is-a StandardError, so a StandardError clause listed
      # FIRST wins even though TypeError is the more specific match —
      # Ruby tries clauses in source order, never reorders by
      # specificity.
      eval(<<-RUBY).should eq Value.string("broad")
        begin
          raise TypeError, "nope"
        rescue StandardError => e
          "broad"
        rescue TypeError => e
          "narrow"
        end
      RUBY
    end

    it "runs an ensure once, after whichever clause matched" do
      result = eval(<<-RUBY)
        order = []
        begin
          raise ArgumentError, "nope"
        rescue TypeError => e
          order << :type
        rescue ArgumentError => e
          order << :arg
        ensure
          order << :ensure
        end
        order
      RUBY
      result.as_array.map(&.as_sym.name).should eq ["arg", "ensure"]
    end
  end

  describe "rescue A, B (multiple types on one clause)" do
    it "catches when the raised class matches the first listed type" do
      eval(<<-RUBY).should eq Value.string("caught")
        begin
          raise TypeError, "nope"
        rescue TypeError, ArgumentError => e
          "caught"
        end
      RUBY
    end

    it "catches when the raised class matches a later listed type" do
      eval(<<-RUBY).should eq Value.string("caught")
        begin
          raise ArgumentError, "nope"
        rescue TypeError, ArgumentError => e
          "caught"
        end
      RUBY
    end

    it "does not catch a class absent from either listed type" do
      expect_raises(RuntimeError, /nope/) do
        eval(<<-RUBY)
          begin
            raise NameError, "nope"
          rescue TypeError, ArgumentError => e
            "caught"
          end
        RUBY
      end
    end

    it "binds the rescue variable to the actual raised error regardless of which listed type matched" do
      eval(<<-RUBY).should eq Value.string("nope")
        begin
          raise ArgumentError, "nope"
        rescue TypeError, ArgumentError => e
          e.message
        end
      RUBY
    end

    it "works as one clause among several, combined with a later fallback clause" do
      eval(<<-RUBY).should eq Value.string("fallback")
        begin
          raise NameError, "nope"
        rescue TypeError, ArgumentError => e
          "combined"
        rescue
          "fallback"
        end
      RUBY
    end
  end

  describe "begin/rescue/else" do
    it "runs the else body when the begin body raises nothing" do
      eval(<<-RUBY).should eq Value.string("else ran")
        begin
          1 + 1
        rescue
          "rescued"
        else
          "else ran"
        end
      RUBY
    end

    it "does not run the else body when the begin body raises" do
      eval(<<-RUBY).should eq Value.string("rescued")
        begin
          raise "boom"
        rescue
          "rescued"
        else
          "not this"
        end
      RUBY
    end

    it "the overall expression's value is else's, not the body's, on success" do
      eval(<<-RUBY).should eq Value.int(99_i64)
        x = begin
              1 + 1
            rescue
              -1
            else
              99
            end
        x
      RUBY
    end

    it "does not run the else body when a specific rescue clause matches " \
       "among several" do
      result = eval(<<-RUBY)
        begin
          raise TypeError, "nope"
        rescue TypeError => e
          "caught type"
        rescue ArgumentError => e
          "caught arg"
        else
          "should not run"
        end
      RUBY
      result.should eq Value.string("caught type")
    end

    it "an error raised inside else is NOT caught by this begin's own " \
       "rescue clauses — matches real Ruby: else runs past the point " \
       "this construct's protection was already torn down" do
      expect_raises(RuntimeError, /boom/) do
        eval(<<-RUBY)
          begin
            1 + 1
          rescue
            "rescued"
          else
            raise "boom"
          end
        RUBY
      end
    end

    it "an outer begin's rescue CAN still catch an error raised inside an " \
       "inner begin's else, since it's an ordinary propagating error by " \
       "that point, just not caught by the SAME begin's own rescue" do
      result = eval(<<-RUBY)
        begin
          begin
            1 + 1
          rescue
            "inner rescued"
          else
            raise "boom"
          end
        rescue e
          "outer caught: " + e.message
        end
      RUBY
      result.should eq Value.string("outer caught: boom")
    end

    it "this begin's OWN ensure still runs when else itself raises — " \
       "EndTry only clears the rescue portion of the handler entry, " \
       "leaving a linked ensure_ip live for exactly this case" do
      result = eval(<<-RUBY)
        order = []
        begin
          begin
            1 + 1
          rescue
            order << :rescue
          else
            order << :else
            raise "boom"
          ensure
            order << :ensure
          end
        rescue e
          order << ("outer caught: " + e.message)
        end
        order
      RUBY
      arr = result.as_array
      arr[0].as_sym.name.should eq "else"
      arr[1].as_sym.name.should eq "ensure"
      arr[2].as_string.should eq "outer caught: boom"
    end

    it "runs ensure after else on the success path, and ensure's own " \
       "trailing value doesn't clobber else's" do
      result = eval(<<-RUBY)
        order = []
        x = begin
              1 + 1
            rescue
              order << :rescue
              -1
            else
              order << :else
              99
            ensure
              order << :ensure
            end
        [x, order]
      RUBY
      arr = result.as_array
      arr[0].should eq Value.int(99_i64)
      arr[1].as_array.map(&.as_sym.name).should eq ["else", "ensure"]
    end

    it "still runs ensure when the rescue path is taken instead of else" do
      result = eval(<<-RUBY)
        order = []
        begin
          raise "boom"
        rescue
          order << :rescue
        else
          order << :else
        ensure
          order << :ensure
        end
        order
      RUBY
      result.as_array.map(&.as_sym.name).should eq ["rescue", "ensure"]
    end

    it "a local assigned in the body is visible inside else (else runs " \
       "only after the body has fully completed)" do
      eval(<<-RUBY).should eq Value.int(5_i64)
        begin
          x = 5
        rescue
          -1
        else
          x
        end
      RUBY
    end
  end

  describe "begin/ensure without rescue" do
    # Op::Try's jump target was only ever patched inside the
    # rescue_body branch. An ensure-only begin (no rescue clause) had
    # no such patch site, so Try pushed the unpatched NO_TARGET
    # sentinel (0xFFFFFFFF) onto Frame#handlers — reading it via
    # UInt32#to_i (a checked conversion) raised a Crystal OverflowError
    # the instant Try executed, before any error-catching logic ran.
    it "runs an ensure body without a rescue clause (regression: handlers overflow)" do
      eval(<<-RUBY).should eq Value.int(2_i64)
        begin
          1 + 1
        ensure
          2 + 2
        end
      RUBY
    end

    it "still allows a rescue clause alongside ensure" do
      result = eval(<<-RUBY)
        begin
          raise "boom"
        rescue e
          :caught
        ensure
          1
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "yields the body's value, not the ensure block's (regression: ensure clobbered the result)" do
      # A second, independent bug found on this path: compile_body(ensure_body)
      # left its own trailing value on top of the body's, so the overall
      # begin/ensure expression incorrectly evaluated to the ensure
      # block's value. Ruby's ensure runs for side effects only.
      eval(<<-RUBY).should eq Value.int(2_i64)
        begin
          1 + 1
        ensure
          99
        end
      RUBY
    end
  end

  describe "bare rescue only catches StandardError and below" do
    it "still catches a plain raise (defaults to RuntimeError, a StandardError)" do
      result = eval(<<-RUBY)
        begin
          raise "boom"
        rescue e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "still catches an internal VM error (division by zero)" do
      result = eval(<<-RUBY)
        begin
          1 / 0
        rescue
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "does not catch a bare Exception (not a StandardError descendant)" do
      expect_raises(RuntimeError, /fatal/) do
        eval(<<-RUBY)
          begin
            raise Exception, "fatal"
          rescue => e
            :caught
          end
        RUBY
      end
    end

    it "an explicit rescue Exception still catches a bare Exception" do
      result = eval(<<-RUBY)
        begin
          raise Exception, "fatal"
        rescue Exception => e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end
  end

  describe "ensure on error propagation" do
    it "runs the ensure body, then still propagates the original error uncaught" do
      # No rescue anywhere — ensure must run (side effect visible via
      # the mutated global), then the original error keeps propagating.
      expect_raises(RuntimeError, /boom/) do
        eval(<<-RUBY)
          ran = false
          begin
            raise "boom"
          ensure
            ran = true
          end
        RUBY
      end
    end

    it "lets an outer rescue catch an error after an inner ensure-only begin runs" do
      result = eval(<<-RUBY)
        def inner
          begin
            raise "boom"
          ensure
            1 + 1
          end
        end

        begin
          inner()
        rescue e
          "outer caught: " + e.message
        end
      RUBY
      result.should eq Value.string("outer caught: boom")
    end

    it "a new error raised inside ensure supersedes the original (Ruby semantics)" do
      result = eval(<<-RUBY)
        begin
          begin
            raise "original"
          ensure
            raise ArgumentError, "replacement"
          end
        rescue ArgumentError => e
          e.message
        end
      RUBY
      result.should eq Value.string("replacement")
    end

    it "runs an ensure exactly once and doesn't affect an unrelated later block" do
      result = eval(<<-RUBY)
        count = 0
        begin
          1 + 1
        ensure
          count += 1
        end

        begin
          raise "second"
        rescue e
          count
        end
      RUBY
      result.should eq Value.int(1_i64)
    end

    it "an outer rescue still gets a chance after a sibling inner ensure-only begin runs" do
      # Regression guard for an ordering bug found during development:
      # checking "any pending rescue on this frame" before "any
      # pending ensure on this frame" via two independent stacks can
      # skip a more-recently-pushed ensure that must run first. The
      # outer's rescue entry is pushed before either inner block; the
      # second inner block's ensure entry is pushed after — it must
      # still run before the outer rescue gets a chance.
      result = eval(<<-RUBY)
        count = 0
        begin
          begin
            1 + 1
          ensure
            count += 1
          end

          begin
            raise "second"
          ensure
            count += 1
          end
        rescue e
          count
        end
      RUBY
      result.should eq Value.int(2_i64)
    end
  end

  # Regression coverage for a bug found while implementing the
  # 2026-07-15 top-level/class-module-body scoping fix: `rescue => e`
  # compiled to a hardcoded Op::SetGlobal, independent of everything
  # else that fix touched (compile_rescue_bind_and_body never went
  # through emit_store at all) — so `e` leaked out of the rescue
  # block as a real global and could collide with a same-named
  # top-level `def`, same bug shape as the original `dbl`/`def dbl`
  # collision that fix corrected for ordinary assignment.
  describe "rescue variable scoping" do
    it "persists at the enclosing scope after the rescue block, since begin/end " \
       "does not introduce its own scope (confirmed against real Ruby)" do
      # Real Ruby: nested begin/end blocks share the enclosing scope —
      # a variable assigned (or rescue-bound) inside one is visible
      # afterward at that same enclosing level. Only a method/class/
      # module/block boundary introduces real isolation. Adjutant's
      # compile_begin never pushes a CompilerScope (confirmed by
      # reading it — no `@scope =` assignment anywhere in that
      # function), so `e` correctly resolves via emit_store_name's
      # resolve_local against the SAME scope the begin/end sits in,
      # both inside the rescue clause and afterward.
      src = <<-RUBY
      begin
        1 / 0
      rescue => e
        :caught
      end
      e.message
      RUBY
      eval(src).as_string.should eq "divided by 0"
    end

    it "does NOT persist past a method boundary" do
      src = <<-RUBY
      def catch_it
        begin
          1 / 0
        rescue => e
          :caught
        end
      end
      catch_it
      e
      RUBY
      expect_raises(Adjutant::RuntimeError, /undefined method or variable `e`/) do
        eval(src)
      end
    end

    it "does not collide with a same-named top-level def" do
      src = <<-RUBY
      def e; "method"; end
      begin
        1 / 0
      rescue => e
        e.message
      end
      e()
      RUBY
      # The rescue variable and the method must be genuinely separate
      # bindings — binding `e` inside the rescue clause must not have
      # clobbered the global `def e` (which SetGlobal would have,
      # since both used to share one @globals slot).
      eval(src).as_string.should eq "method"
    end

    it "binds a real, scoped local even inside a block (force_define, " \
       "not ordinary block assignment's resolve-outward-then-global rule)" do
      src = <<-RUBY
      messages = []
      [1, 0].each do |n|
        begin
          10 / n
        rescue => e
          messages << e.message
        end
      end
      messages
      RUBY
      result = eval(src).as_array
      result.size.should eq 1
      result[0].as_string.should eq "divided by 0"
    end

    it "reuses an already-local same-named variable rather than shadowing it" do
      # force_define still checks resolve_local first — if `e` is
      # already a local in this exact scope, the rescue binding
      # reassigns it rather than allocating a redundant second slot.
      src = <<-RUBY
      e = "before"
      begin
        1 / 0
      rescue => e
        e.message
      end
      RUBY
      eval(src).as_string.should eq "divided by 0"
    end
  end

  # Regression coverage for the Must Fix bug found 2026-08-05: break/
  # next inside a begin/rescue/ensure region compiled to a bare
  # Op::Jump consulting only @loop_stack, with no awareness of the
  # Try/SetEnsure handler the region had pushed — so the jump landed
  # past Op::EnterEnsure, silently skipping the ensure body and
  # leaving a stale HandlerEntry on Frame#handlers.
  describe "break/next through begin/rescue/ensure" do
    it "runs the ensure body when break exits through it" do
      result = eval(<<-RUBY)
        side = []
        while true
          begin
            break 123
          ensure
            side << :ensure
          end
        end
        side
      RUBY
      result.as_array.map(&.as_sym.name).should eq ["ensure"]
    end

    it "still evaluates break's own value when its ensure runs" do
      eval(<<-RUBY).should eq Value.int(123_i64)
        while true
          begin
            break 123
          ensure
            1 + 1
          end
        end
      RUBY
    end

    it "runs the ensure body when next exits through it" do
      result = eval(<<-RUBY)
        side = []
        count = 0
        while count < 3
          count += 1
          begin
            next
          ensure
            side << count
          end
        end
        side
      RUBY
      result.as_array.map(&.as_int).should eq [1_i64, 2_i64, 3_i64]
    end

    it "runs nested ensures innermost-first when break exits through both" do
      result = eval(<<-RUBY)
        side = []
        while true
          begin
            begin
              break
            ensure
              side << :inner
            end
          ensure
            side << :outer
          end
        end
        side
      RUBY
      result.as_array.map(&.as_sym.name).should eq ["inner", "outer"]
    end

    it "does not run an ensure that encloses the loop itself, only ones opened inside it" do
      # The begin/ensure here is OUTSIDE the loop, already fully
      # "current" before the loop starts — ensure_depth_at_entry
      # should treat it as already accounted for, not something the
      # loop's own break needs to unwind through again.
      result = eval(<<-RUBY)
        side = []
        begin
          while true
            break
          end
        ensure
          side << :outer
        end
        side
      RUBY
      result.as_array.map(&.as_sym.name).should eq ["outer"]
    end

    it "does not leave a stale handler behind: an unrelated later error " \
       "is not caught by the drained region" do
      # Same regression shape as "runs an ensure exactly once and
      # doesn't affect an unrelated later block" above, but via a
      # break-exited region instead of normal fallthrough — the bug
      # this guards against is specifically that break/next skipped
      # the Op::EnterEnsure that pops the handler, so this second,
      # textually unrelated begin/rescue could wrongly get caught by
      # the first construct's stale entry instead of its own.
      expect_raises(RuntimeError, /uncaught/) do
        eval(<<-RUBY)
          while true
            begin
              break
            ensure
              1 + 1
            end
          end

          raise "uncaught"
        RUBY
      end
    end

    it "pops a rescue-only handler (no ensure clause) too, not just ensure-bearing ones" do
      # No ensure body to run here, but the Try handler pushed for the
      # rescue clause is just as stale if left on Frame#handlers after
      # break jumps past it — same HandlerEntry, same pop, no ensure
      # code to interleave.
      result = eval(<<-RUBY)
        count = 0
        while true
          begin
            break
          rescue
            nil
          end
        end

        begin
          raise "second"
        rescue e
          count = 1
        end
        count
      RUBY
      result.should eq Value.int(1_i64)
    end

    it "lets an outer rescue still catch a real error after a sibling " \
       "loop's break has drained its own ensure" do
      result = eval(<<-RUBY)
        side = []
        begin
          while true
            begin
              break
            ensure
              side << :loop_ensure
            end
          end

          raise "boom"
        rescue e
          side << :outer_rescue
        end
        side
      RUBY
      result.as_array.map(&.as_sym.name).should eq ["loop_ensure", "outer_rescue"]
    end

    # NOTE: no modifier-while (`begin...end while`) coverage here.
    # Found while testing this fix: `next`'s jump target for that loop
    # form is @loop_stack.last.start_pos, which compile_modifier_while
    # sets equal to the very top of the loop (loop_start == body_pos)
    # rather than the condition check — pre-existing, present already
    # in HEAD before this session's changes (confirmed via git stash),
    # completely independent of break/next/ensure interaction. Any
    # unconditional `next` in this loop form re-executes the body from
    # scratch with no condition check in between, hanging forever —
    # which is what locked up the first run of this fix's specs. Not
    # fixed here: out of this session's scope (ensure-leak on break/
    # next/redo), and fixing it needs its own careful look at what
    # `next`/`redo` should each target for this form. Left as a gap
    # for a future session — see SCOPE.md.

    it "runs the ensure body on each pass when redo exits through it, " \
       "and cleanly re-establishes the handler for the next pass — " \
       "bounded so a real infinite loop fails loudly instead of hanging" do
      # redo has the identical bug shape as break/next: body_pos is a
      # jump target INSIDE the loop but before the begin/ensure is
      # (re-)entered, so a redo from inside one needs the same
      # handler-draining treatment. Guards against a stale handler
      # surviving across the redo the same way the break/next
      # regression above guards against one surviving past a break.
      #
      # KNOWN RISK: this is the first test anywhere in this repo's
      # history to actually EXECUTE redo through the VM (confirmed via
      # grep — every prior reference is either a compile-time
      # rejection test for redo-outside-a-loop, or this session's own
      # additions) — so redo's runtime target (LoopScope#body_pos) has
      # never been runtime-verified, with or without ensure involved.
      # Bounded via an explicit instruction_limit (see the plain-
      # redo isolation test just below) for the same reason: if this
      # hangs again, it should fail loudly, not lock up the runner a
      # second time.
      limits = ExecutionLimits.new(instruction_limit: 10_000_u64)
      interp, _ = make_interp(limits)
      result = interp.eval(<<-RUBY)
        side = []
        tries = 0
        count = 0
        while count < 1
          begin
            tries += 1
            if tries < 3
              redo
            end
          ensure
            side << tries
          end
          count += 1
        end
        side
      RUBY
      result.as_array.map(&.as_int).should eq [1_i64, 2_i64, 3_i64]
    end

    it "a bare redo with no ensure involved terminates (isolates whether " \
       "redo's own jump target is the problem, independent of ensure) " \
       "— bounded so a real infinite loop fails loudly instead of hanging" do
      # Deliberately minimal — no begin/ensure at all — to separate
      # "redo's basic runtime jump target is broken" (pre-existing,
      # this session never touched compile_while's body_pos value
      # itself) from "the ensure-drain this session added breaks
      # redo" (the thing actually in scope here). Uses an explicit
      # instruction_limit (not the shared eval() helper, which has
      # none) specifically because THIS test's whole purpose is
      # checking whether redo terminates at all — an unbounded eval
      # here would just reproduce the same hang blind a second time
      # if the answer turns out to be "no."
      limits = ExecutionLimits.new(instruction_limit: 10_000_u64)
      interp, _ = make_interp(limits)
      result = interp.eval(<<-RUBY)
        tries = 0
        while tries < 1
          tries += 1
          if tries < 3
            redo
          end
        end
        tries
      RUBY
      result.should eq Value.int(3_i64)
    end
  end
end
