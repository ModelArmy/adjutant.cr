require "../../../spec_helper"

module Adjutant
  describe "Legate.env" do
    it "returns the value of an allowlisted, set variable" do
      ENV["ADJUTANT_SPEC_VAR"] = "hello"
      begin
        interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_VAR"]))
        eval = interp.eval(%(Legate.env("ADJUTANT_SPEC_VAR")))
        eval.as_string.should eq "hello"
      ensure
        ENV.delete("ADJUTANT_SPEC_VAR")
      end
    end

    it "returns nil for an allowlisted but unset variable" do
      ENV.delete("ADJUTANT_SPEC_VAR_UNSET")
      interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_VAR_UNSET"]))
      eval = interp.eval(%(Legate.env("ADJUTANT_SPEC_VAR_UNSET").nil?.to_s))
      eval.as_string.should eq "true"
    end

    it "denies with a FatalSignal for a name outside the allowlist" do
      interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ALLOWED_ONE"]))
      expect_raises(Legate::FatalSignal, /Legate\.env denied/) do
        interp.eval(%(Legate.env("NOT_ALLOWED")))
      end
    end

    it "denies with a FatalSignal when no ambient.env allowlist is granted at all" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      expect_raises(Legate::FatalSignal, /Legate\.env denied/) do
        interp.eval(%(Legate.env("ANYTHING")))
      end
    end

    it "the allowlist denial is a real FatalSignal — unrescuable, kind :denied" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      begin
        interp.eval(<<-RUBY)
        begin
          Legate.env("NOT_ALLOWED")
        rescue Exception => e
          "swallowed"
        end
        RUBY
        fail "expected Legate::FatalSignal to propagate"
      rescue ex : Legate::FatalSignal
        ex.kind.should eq :denied
      end
    end

    it "raises ArgumentError (R043) when name is missing" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.env
        "no error"
      rescue ArgumentError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when name isn't a String" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.env(42)
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    describe "audit log" do
      it "logs exactly one :allowed record for an allowlisted, set variable" do
        ENV["ADJUTANT_SPEC_VAR"] = "hello"
        begin
          interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_VAR"]))
          interp.eval(%(Legate.env("ADJUTANT_SPEC_VAR")))
          records = interp.broker.audit_log.records.select { |r| r.verb == "env" }
          records.size.should eq 1
          records.first.decision.should eq :allowed
          records.first.authority.should eq Authority::Ambient
          records.first.subject.should eq "ADJUTANT_SPEC_VAR"
        ensure
          ENV.delete("ADJUTANT_SPEC_VAR")
        end
      end

      it "logs an :allowed record for an allowlisted but unset variable" do
        ENV.delete("ADJUTANT_SPEC_VAR_UNSET")
        interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_VAR_UNSET"]))
        interp.eval(%(Legate.env("ADJUTANT_SPEC_VAR_UNSET")))
        records = interp.broker.audit_log.records.select { |r| r.verb == "env" }
        records.map(&.decision).should eq [:allowed]
      end

      it "logs exactly one :denied record, before raising, for a name outside the allowlist" do
        interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ALLOWED_ONE"]))
        expect_raises(Legate::FatalSignal, /Legate\.env denied: "NOT_ALLOWED" is not in the ambient\.env allowlist/) do
          interp.eval(%(Legate.env("NOT_ALLOWED")))
        end
        records = interp.broker.audit_log.records.select { |r| r.verb == "env" }
        records.size.should eq 1
        records.first.decision.should eq :denied
        records.first.exception_class.should eq "Legate::Denied"
        records.first.subject.should eq "NOT_ALLOWED"
      end

      it "records the variable's name, never its value" do
        ENV["ADJUTANT_SPEC_SECRET"] = "hunter2"
        begin
          interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_SECRET"]))
          interp.eval(%(Legate.env("ADJUTANT_SPEC_SECRET")))
          interp.broker.audit_log.records.none? { |r| r.subject.includes?("hunter2") }.should be_true
        ensure
          ENV.delete("ADJUTANT_SPEC_SECRET")
        end
      end

      # A sensitive, rejected name must fail the same way whether or
      # not it is set; otherwise nil-versus-raise reveals existence.
      it "logs a :rejected record for a sensitive name under a rejecting policy, even when unset" do
        ENV.delete("ADJUTANT_SPEC_SECRET_UNSET")
        policy = RiskFlowPolicy.new(
          sensitivity_patterns: [SensitivityPattern.new(ProvenanceKind::Env, "ADJUTANT_SPEC_SECRET_UNSET", 1, Sensitivity::High)],
          reject_all_flows: true,
        )
        interp, _ = make_interp(
          risk_flow_policy: policy,
          grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_SECRET_UNSET"]),
        )
        expect_raises(RuntimeError, /risk flow policy rejected/) do
          interp.eval(%(Legate.env("ADJUTANT_SPEC_SECRET_UNSET")))
        end
        records = interp.broker.audit_log.records.select { |r| r.verb == "env" }
        records.map(&.decision).should eq [:rejected]
      end
    end
  end
end
