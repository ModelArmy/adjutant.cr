require "../../../spec_helper"
require "log"

module Adjutant
  describe "Legate.log" do
    it "writes the message and fields through the embedder-supplied Log" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      interp.eval(%(Legate.log("hello", {status: "ok", count: 3})))

      backend.entries.size.should eq 1
      entry = backend.entries.first
      entry.message.should eq "hello"
      entry.severity.should eq ::Log::Severity::Info
      entry.source.should eq "adjutant.spec.log"
    end

    it "accepts String-keyed fields exactly as well as Symbol-keyed ones" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      interp.eval(%(Legate.log("hello", {"status" => "ok"})))

      backend.entries.size.should eq 1
    end

    it "defaults fields to empty when the second argument is omitted" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      interp.eval(%(Legate.log("no fields here")))

      backend.entries.size.should eq 1
      backend.entries.first.message.should eq "no fields here"
    end

    it "returns nil" do
      interp, _ = make_interp
      eval = interp.eval(%(Legate.log("x").nil?.to_s))
      eval.as_string.should eq "true"
    end

    it "needs no grant at all — works under Grants.deny_all, same as every ambient verb" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("ambient, no grant needed")
        "no error"
      rescue
        "errored"
      end
      RUBY
      eval.as_string.should eq "no error"
    end

    it "raises ArgumentError (R041) when message is missing" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log
        "no error"
      rescue ArgumentError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when message isn't a String" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log(42)
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when fields isn't a Hash" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("hello", "not a hash")
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when a field value doesn't coerce (e.g. a lambda)" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("hello", {bad: lambda { 1 }})
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "accepts a nested Array/Hash of loggable values" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("hello", {tags: ["a", "b"], nested: {ok: true}})
        "no error"
      rescue
        "errored"
      end
      RUBY
      eval.as_string.should eq "no error"
      backend.entries.size.should eq 1
    end
  end

  # `Authority::Log` is what actually PREVENTS the exfiltration
  # scenario `Effect::ExternalOutput` (above) only makes visible in a
  # static report: a script reading a sensitive value and handing it
  # to `Legate.log` verbatim. Real source (`Legate.env`, not a
  # synthetic trigger — this is the actual shape of the risk, not a
  # standalone unit test of `VM#check_risk_flow`, which
  # `risk_flow_enforcement_spec.cr` already covers in isolation).
  describe "risk-flow enforcement (the actual exfiltration fix, not just the Effect)" do
    it "rejects a High-sensitivity value read via Legate.env reaching Legate.log" do
      ENV["ADJUTANT_SPEC_SECRET"] = "hunter2"
      begin
        policy = RiskFlowPolicy.new(
          sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::Env, "ADJUTANT_SPEC_SECRET", 1, Sensitivity::High)],
          risk_flow_rules: [RiskFlowRule.new(Authority::Log, Sensitivity::High, RiskFlowAction::Reject)],
        )
        interp, _ = make_interp(
          risk_flow_policy: policy,
          grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_SECRET"]),
        )
        expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(<<-RUBY)
          secret = Legate.env("ADJUTANT_SPEC_SECRET")
          Legate.log("leaking", {data: secret})
          RUBY
        end
      ensure
        ENV.delete("ADJUTANT_SPEC_SECRET")
      end
    end

    it "does NOT reject an untainted value under the identical rule — no false positive" do
      policy = RiskFlowPolicy.new(
        risk_flow_rules: [RiskFlowRule.new(Authority::Log, Sensitivity::High, RiskFlowAction::Reject)],
      )
      interp, _ = make_interp(risk_flow_policy: policy, grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("fine", {data: "nothing sensitive here"})
        "no error"
      rescue
        "errored"
      end
      RUBY
      eval.as_string.should eq "no error"
    end

    it "a policy that Allows this Authority/Sensitivity pair lets it through" do
      ENV["ADJUTANT_SPEC_SECRET"] = "hunter2"
      begin
        policy = RiskFlowPolicy.new(
          sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::Env, "ADJUTANT_SPEC_SECRET", 1, Sensitivity::High)],
          risk_flow_rules: [RiskFlowRule.new(Authority::Log, Sensitivity::High, RiskFlowAction::Allow)],
        )
        interp, _ = make_interp(
          risk_flow_policy: policy,
          grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_SECRET"]),
        )
        eval = interp.eval(<<-RUBY)
        begin
          secret = Legate.env("ADJUTANT_SPEC_SECRET")
          Legate.log("leaking", {data: secret})
          "no error"
        rescue
          "errored"
        end
        RUBY
        eval.as_string.should eq "no error"
      ensure
        ENV.delete("ADJUTANT_SPEC_SECRET")
      end
    end
  end
end
