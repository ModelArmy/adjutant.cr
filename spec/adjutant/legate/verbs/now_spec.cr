require "../../../spec_helper"

module Adjutant
  describe "Legate.now" do
    it "returns a real Time — the same class a bare Time.now returns" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(%(Legate.now.class == Time.now.class))
      eval.truthy?.should be_true
    end

    it "is a Time via is_a?" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(%(Legate.now.is_a?(Time)))
      eval.truthy?.should be_true
    end

    it "needs no grant at all — works under Grants.deny_all, same as every ambient verb" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.now
        "no error"
      rescue
        "errored"
      end
      RUBY
      eval.as_string.should eq "no error"
    end

    it "logs no audit record — ambient verbs are not authorized against" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      interp.eval(%(Legate.now))
      interp.broker.audit_log.records.should be_empty
    end
  end
end
