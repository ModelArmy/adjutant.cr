require "../../../spec_helper"

module Adjutant
  describe "Legate.random" do
    it "with no argument returns a Float in [0.0, 1.0)" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      result = interp.eval(%(Legate.random))
      result.float?.should be_true
      result.as_float.should be >= 0.0
      result.as_float.should be < 1.0
    end

    it "with an explicit nil behaves the same as no argument" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      result = interp.eval(%(Legate.random(nil)))
      result.float?.should be_true
    end

    it "with a positive Integer n returns an Integer in [0, n)" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      result = interp.eval(%(Legate.random(10)))
      result.int?.should be_true
      result.as_int.should be >= 0
      result.as_int.should be < 10
    end

    it "with a positive Float n returns a Float in [0, n)" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      result = interp.eval(%(Legate.random(2.5)))
      result.float?.should be_true
      result.as_float.should be >= 0.0
      result.as_float.should be < 2.5
    end

    it "raises ArgumentError (R042) for n == 0" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.random(0)
        "no error"
      rescue ArgumentError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises ArgumentError (R042) for a negative n" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.random(-3)
        "no error"
      rescue ArgumentError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when n isn't Integer, Float, or nil" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.random("nope")
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "needs no grant at all — works under Grants.deny_all, same as every ambient verb" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.random
        "no error"
      rescue
        "errored"
      end
      RUBY
      eval.as_string.should eq "no error"
    end

    it "logs no audit record — ambient verbs are not authorized against" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      interp.eval(%(Legate.random))
      interp.broker.audit_log.records.should be_empty
    end
  end
end
