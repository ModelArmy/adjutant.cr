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

    it "logs no audit record on success either — ambient verbs are not authorized against" do
      ENV["ADJUTANT_SPEC_VAR"] = "hello"
      begin
        interp, _ = make_interp(grants: Legate::Grants.new(ambient_env: ["ADJUTANT_SPEC_VAR"]))
        interp.eval(%(Legate.env("ADJUTANT_SPEC_VAR")))
        interp.broker.audit_log.records.should be_empty
      ensure
        ENV.delete("ADJUTANT_SPEC_VAR")
      end
    end
  end
end
