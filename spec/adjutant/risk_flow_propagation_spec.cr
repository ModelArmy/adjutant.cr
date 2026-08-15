require "../spec_helper"

module Adjutant
  # Helper: an interpreter with flow tracking enabled and a native
  # function `tainted(origin)` that returns an Integer(1) labeled with a
  # single File tag at the given origin and Sensitivity::High — a
  # minimal stand-in for what a real native module (e.g. file IO) would
  # do once the sensitivity policy exists (see research/IFC_DESIGN.md).
  private def self.make_tainted_interp : {Interpreter, TestEffectHandler}
    ef = TestEffectHandler.new
    interp = Interpreter.new(
      risk_flow_policy: RiskFlowPolicy.reject_all,
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      effect: ef,
      risk_flow_tracking: true,
    )
    interp.define_native("tainted") do |args|
      origin = args.first.as_string
      Value.int(1_i64, RiskFlowLabel.of(ProvenanceKind::File, origin, Sensitivity::High))
    end
    interp.define_native("tainted_str") do |args|
      origin = args.first.as_string
      Value.string("x", RiskFlowLabel.of(ProvenanceKind::File, origin, Sensitivity::High))
    end
    {interp, ef}
  end

  describe "IFC label propagation through VM dispatch (Stage 3)" do
    describe "arithmetic (exec_binary)" do
      it "joins labels across Add" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") + 1))
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/passwd"
      end

      it "an unlabeled result stays unlabeled" do
        interp, _ = make_tainted_interp
        interp.eval("1 + 1").label.should be_nil
      end

      it "joins labels from both operands when both are tainted" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") + tainted("/etc/shadow")))
        label = result.label.not_nil!
        label.tags.size.should eq 2
      end

      it "records a RiskFlowEvent for Add" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd") + 1))
        events = interp.risk_flow_log.events.select { |e| e.op == "Add" }
        events.size.should eq 1
        events.first.result.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "joins across comparison ops" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") < 5))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    describe "Op::Eq" do
      it "joins labels across equality comparison" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd") == 1))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for Eq" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd") == 1))
        interp.risk_flow_log.events.map(&.op).should contain "Eq"
      end
    end

    describe "Op::Concat (string interpolation)" do
      it "joins labels across interpolated parts" do
        interp, _ = make_tainted_interp
        result = interp.eval(%q("value: #{tainted_str("/etc/passwd")}"))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for Concat" do
        interp, _ = make_tainted_interp
        interp.eval(%q("value: #{tainted_str("/etc/passwd")}"))
        interp.risk_flow_log.events.map(&.op).should contain "Concat"
      end
    end

    describe "Op::MakeArray" do
      it "joins labels across array elements onto the array's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%([1, tainted("/etc/passwd"), 3]))
        result.array?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "an array of unlabeled elements stays unlabeled" do
        interp, _ = make_tainted_interp
        interp.eval("[1, 2, 3]").label.should be_nil
      end

      it "records a RiskFlowEvent for MakeArray" do
        interp, _ = make_tainted_interp
        interp.eval(%([1, tainted("/etc/passwd"), 3]))
        interp.risk_flow_log.events.map(&.op).should contain "MakeArray"
      end
    end

    # A splat param collecting call args (VM#bind_args/#collect_splat,
    # added 2026-08-03 alongside the default-parameter prologue — see
    # SCOPE.md's Must Fix) builds an Array exactly the way Op::MakeArray
    # does, just from positional call args instead of a `[...]` literal
    # — these specs pin that it's genuinely the same KIND of event to a
    # risk-flow log/policy, not a container IFC silently can't see
    # through.
    describe "a splat param collecting args (VM#collect_splat)" do
      it "joins labels across collected elements onto the array's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def sum(*args)
            args
          end
          sum(1, tainted("/etc/passwd"), 3)
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "a splat of unlabeled elements stays unlabeled" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def sum(*args)
            args
          end
          sum(1, 2, 3)
        RUBY
        result.label.should be_nil
      end

      it "records a RiskFlowEvent under the MakeArray op name" do
        interp, _ = make_tainted_interp
        interp.eval(<<-RUBY)
          def sum(*args)
            args
          end
          sum(1, tainted("/etc/passwd"), 3)
        RUBY
        interp.risk_flow_log.events.map(&.op).should contain "MakeArray"
      end

      it "a splat with nothing left to collect is unlabeled, not just empty" do
        # Zero elements means the reduce never runs, so joined_label
        # stays nil — an empty splat-collected array must be exactly
        # as inert to IFC as `[]` is, not carry some leftover label
        # from a prior call.
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def sum(*args)
            args
          end
          sum
        RUBY
        result.label.should be_nil
      end
    end

    describe "Op::MakeHash" do
      it "joins labels across keys and values onto the hash's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%({"k" => tainted("/etc/passwd")}))
        result.hash?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for MakeHash" do
        interp, _ = make_tainted_interp
        interp.eval(%({"k" => tainted("/etc/passwd")}))
        interp.risk_flow_log.events.map(&.op).should contain "MakeHash"
      end
    end

    describe "Op::MakeRange" do
      it "joins labels from start and end" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted("/etc/passwd")..5))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for MakeRange" do
        interp, _ = make_tainted_interp
        interp.eval(%(tainted("/etc/passwd")..5))
        interp.risk_flow_log.events.map(&.op).should contain "MakeRange"
      end
    end

    describe "Op::SetIndex (container accumulation, Stage 4)" do
      it "accumulates a tainted element's label onto the array's own label" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
          arr
        RUBY
        result.array?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "the accumulated label is visible via a later GetLocal read of the same array" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
          post_target = arr
          post_target
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "does not taint the array when the assigned value is unlabeled" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = 99
          arr
        RUBY
        result.label.should be_nil
      end

      it "accumulates onto a Hash's own label the same way" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1}
          h["a"] = tainted("/etc/passwd")
          h
        RUBY
        result.hash?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for SetIndex" do
        interp, _ = make_tainted_interp
        interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
        RUBY
        events = interp.risk_flow_log.events.select { |e| e.op == "SetIndex" }
        events.size.should eq 1
        events.first.result.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "labels accumulate monotonically — overwriting the tainted slot does not clear the array's label" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] = tainted("/etc/passwd")
          arr[0] = "clean"
          arr
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    # Op::SetIndexFromValue (2026-08-08) — the compound/conditional/
    # multi-assign-into-an-index sibling of Op::SetIndex directly
    # above. Both opcodes call the exact same exec_set_index, so the
    # accumulation behavior itself is not new — this describe block
    # exists because, until now, NOTHING exercised that shared join
    # logic from this opcode specifically. That gap is exactly how
    # this session's SetIndexFromValue bug (target/index/value
    # scrambled at runtime — see compiler.cr's emit_store `Index`
    # case comment for the full trace) went unnoticed for as long as
    # it did: a propagation test here would have caught the join
    # running on garbage operands directly, independent of whether
    # anyone happened to also write a purely functional regression
    # for the same shape.
    describe "Op::SetIndexFromValue (compound/conditional assignment into an index)" do
      it "accumulates a tainted value's label onto the array via +=" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] += tainted("/etc/passwd")
          arr
        RUBY
        result.array?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "accumulates via ||= too, not just +=" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [nil, 2, 3]
          arr[0] ||= tainted("/etc/passwd")
          arr
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "the accumulated label is visible via a later GetLocal read of the same array" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] += tainted("/etc/passwd")
          post_target = arr
          post_target
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "does not taint the array when the assigned value is unlabeled" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] += 1
          arr
        RUBY
        result.label.should be_nil
      end

      it "accumulates onto a Hash's own label the same way" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          h = {"a" => 1}
          h["a"] += tainted("/etc/passwd")
          h
        RUBY
        result.hash?.should be_true
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "records a RiskFlowEvent for SetIndexFromValue, distinct from plain SetIndex" do
        interp, _ = make_tainted_interp
        interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] += tainted("/etc/passwd")
        RUBY
        events = interp.risk_flow_log.events.select { |e| e.op == "SetIndexFromValue" }
        events.size.should eq 1
        events.first.result.not_nil!.sensitivity.should eq Sensitivity::High
        interp.risk_flow_log.events.any? { |e| e.op == "SetIndex" }.should be_false
      end

      it "labels accumulate monotonically here too — a later clean += does not clear the array's label" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [1, 2, 3]
          arr[0] += tainted("/etc/passwd")
          arr[0] += 1
          arr
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "a MultiAssign target that's an index accumulates the same way (the third affected call site)" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = [0, 0]
          b = nil
          arr[0], b = tainted("/etc/passwd"), 9
          arr
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    # Op::SetAttr (2026-08-08) — recv.attr = value dispatching to a
    # real (script-defined) setter method. Unlike Op::SetIndex/
    # Op::SetIndexFromValue, there is no container-level label to
    # accumulate here — a RubyObject's ivars are independently
    # labeled, each via its own ordinary Op::SetIvar write inside the
    # called setter's body (see that opcode's own comment, vm.cr, for
    # why it does no join of its own). What IS worth a direct test:
    # that the label survives the round trip through Op::SetAttr's
    # VM#call_method dispatch (an isolated @frames/@stack swap) and
    # is still readable afterward via the generated getter.
    describe "Op::SetAttr (recv.attr = value)" do
      it "a tainted value assigned through a setter is still tainted when read back via the getter" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          class Box
            attr_accessor :value
          end
          b = Box.new
          b.value = tainted("/etc/passwd")
          b.value
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "an unlabeled value assigned through a setter stays unlabeled" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          class Box
            attr_accessor :value
          end
          b = Box.new
          b.value = 42
          b.value
        RUBY
        result.label.should be_nil
      end

      it "the assignment expression's own value carries the label too, not just the later read" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          class Box
            attr_accessor :value
          end
          b = Box.new
          b.value = tainted("/etc/passwd")
          RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "a hand-written setter with extra logic still preserves the label on its own ivar write" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          class Box
            def value=(v)
              @stored = v
            end

            def stored
              @stored
            end
          end
          b = Box.new
          b.value = tainted("/etc/passwd")
          b.stored
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    describe "Op::Shl (<<, container accumulation)" do
      it "accumulates a pushed tainted value's label onto the array" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = []
          arr << tainted("/etc/passwd")
          arr
        RUBY
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "chained << calls all accumulate" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          arr = []
          arr << 1 << tainted("/etc/passwd") << 3
          arr
        RUBY
        result.array?.should be_true
        result.as_array.size.should eq 3
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end
    end

    describe "risk_flow_log disabled by default" do
      it "records nothing when flow_tracking is not enabled" do
        ef = TestEffectHandler.new
        interp = Interpreter.new(
          risk_flow_policy: RiskFlowPolicy.reject_all,
          on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
          effect: ef,
        )
        interp.define_native("tainted") do |args|
          Value.int(1_i64, RiskFlowLabel.of(ProvenanceKind::File, args.first.as_string, Sensitivity::High))
        end
        result = interp.eval(%(tainted("/etc/passwd") + 1))
        # Propagation itself is independent of risk_flow_log — label still joins.
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
        interp.risk_flow_log.events.should be_empty
      end
    end

    # Closes the "verify IFC label propagation through lambdas" Must
    # Fix item (SCOPE.md) — the dynamic-label counterpart to the
    # 2026-07-20 VALUE-level closure-capture fix (#17,
    # research/IFC_DESIGN.md's "VM propagation" section). That fix
    # made a lambda's closure resolve to the right VALUE regardless of
    # which frame calls it; these specs confirm a LABELED value
    # specifically still carries its label correctly through the same
    # paths — capture into a closure (GetOuter/SetOuter, "free
    # propagation" per the design doc, since Value is a struct copied
    # whole) and a lambda body's own result flowing back out through
    # `.call` (VM#invoke_proc, unrelated to exec_binary's join logic
    # tested elsewhere in this file — a lambda's return value is
    # whatever its body's last expression evaluates to, propagated by
    # the ordinary rules already covered above, not a special path of
    # its own).
    describe "lambdas and Proc#call" do
      it "a label survives capture into a lambda's closure and a same-frame .call" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          secret = tainted("/etc/passwd")
          wrap = ->() { secret }
          wrap.call
        RUBY
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/passwd"
      end

      it "a label survives a lambda returned out of its defining frame and .call'd from elsewhere" do
        # Same shape as proc_spec.cr's "closes over its defining
        # frame's local..." regression (the VALUE-level version of
        # this exact test) — a lambda captures a labeled local, is
        # returned out of the function that defined it, and is called
        # later from a completely different frame (top level).
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def make_wrapper
            secret = tainted("/etc/passwd")
            ->() { secret }
          end

          wrap = make_wrapper
          wrap.call
        RUBY
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/passwd"
      end

      it "a label on a lambda's own computed result survives .call's return, not just a bare captured value" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          add_taint = ->() { tainted("/etc/shadow") + 1 }
          add_taint.call
        RUBY
        label = result.label.not_nil!
        label.sensitivity.should eq Sensitivity::High
        label.tags.first.origin.should eq "/etc/shadow"
      end

      it "a labeled value captured by a lambda still joins correctly with another tainted value inside the lambda body" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def make_combiner
            a = tainted("/etc/passwd")
            ->() { a + tainted("/etc/shadow") }
          end
          make_combiner.call
        RUBY
        label = result.label.not_nil!
        label.tags.size.should eq 2
      end

      it "an unlabeled value captured by a lambda stays unlabeled through .call" do
        interp, _ = make_tainted_interp
        result = interp.eval(<<-RUBY)
          def make_wrapper
            plain = 42
            ->() { plain }
          end
          make_wrapper.call
        RUBY
        result.label.should be_nil
      end
    end

    # Regexp/MatchData are native-method-dispatch label joining, not
    # VM-opcode-level (Op::Concat/Op::MakeArray/etc above all fire a
    # real RiskFlowEvent because they're opcodes the VM's own dispatch
    # loop instruments directly) — a native method just constructs a
    # labeled Value itself, so there's no "records a RiskFlowEvent"
    # assertion to make here the way the opcode-level describe blocks
    # above have; only the resulting label itself is checked. Added
    # 2026-08-14 auditing the whole Regexp/MatchData feature against
    # this file's own established principle after finding `label`
    # never appeared anywhere in `builtins/regexp.cr` at all — every
    # construction there defaulted to an unlabeled `nil`, a real gap
    # this describe block exists specifically to keep from
    # regressing.
    describe "Regexp / MatchData (native method label joining)" do
      it "Regexp.new(tainted pattern).source carries the label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(Regexp.new(tainted_str("/etc/passwd")).source))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "an interpolated regex literal's #source carries the interpolated label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%q(/a#{tainted_str("/etc/passwd")}b/.source))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "Regexp#match's MatchData inherits the SUBJECT string's label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(/x/.match(tainted_str("/etc/passwd"))[0]))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "Regexp#match's MatchData ALSO inherits a tainted PATTERN's label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%q(Regexp.new(tainted_str("/etc/passwd")).match("xx")[0]))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "MatchData#captures elements carry the label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(/(x)/.match(tainted_str("/etc/passwd")).captures[0]))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "MatchData#pre_match / #post_match / #string carry the label" do
        interp, _ = make_tainted_interp
        pre = interp.eval(%(/x/.match(tainted_str("/etc/passwd")).pre_match))
        post = interp.eval(%(/x/.match(tainted_str("/etc/passwd")).post_match))
        str = interp.eval(%(/x/.match(tainted_str("/etc/passwd")).string))
        pre.label.not_nil!.sensitivity.should eq Sensitivity::High
        post.label.not_nil!.sensitivity.should eq Sensitivity::High
        str.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "String#match's MatchData inherits the RECEIVER string's label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(tainted_str("/etc/passwd").match("x")[0]))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "String#sub/#gsub results carry the receiver's label" do
        interp, _ = make_tainted_interp
        sub = interp.eval(%(tainted_str("/etc/passwd").sub("x", "y")))
        gsub = interp.eval(%(tainted_str("/etc/passwd").gsub("x", "y")))
        sub.label.not_nil!.sensitivity.should eq Sensitivity::High
        gsub.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "String#gsub's result ALSO carries a tainted PATTERN's label" do
        interp, _ = make_tainted_interp
        result = interp.eval(%q("xx".gsub(Regexp.new(tainted_str("x")), "y")))
        result.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "String#split's array AND its elements carry the receiver's label" do
        interp, _ = make_tainted_interp
        arr = interp.eval(%(tainted_str("/etc/passwd").split(",")))
        arr.label.not_nil!.sensitivity.should eq Sensitivity::High
        arr.as_array.first.label.not_nil!.sensitivity.should eq Sensitivity::High
      end

      it "an unlabeled match stays unlabeled (negative case)" do
        interp, _ = make_tainted_interp
        interp.eval(%(/b./.match("abc")[0])).label.should be_nil
      end

      it "#begin/#end stay unlabeled — position metadata, not extracted data" do
        interp, _ = make_tainted_interp
        result = interp.eval(%(/x/.match(tainted_str("/etc/passwd")).begin(0)))
        result.label.should be_nil
      end

      it "#match?/#=== stay unlabeled — a boolean fact, not extracted data" do
        interp, _ = make_tainted_interp
        match_q = interp.eval(%(/x/.match?(tainted_str("/etc/passwd"))))
        eqeqeq = interp.eval(%(/x/.===(tainted_str("/etc/passwd"))))
        match_q.label.should be_nil
        eqeqeq.label.should be_nil
      end
    end
  end
end
