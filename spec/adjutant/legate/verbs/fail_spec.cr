require "../../../spec_helper"

module Adjutant
  describe "Legate.fail" do
    it "raises FatalSignal with kind :aborted and the script's own message, verbatim" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      expect_raises(Legate::FatalSignal, /missing required config/) do
        interp.eval(%(Legate.fail("missing required config")))
      end
    end

    it "carries the message unprefixed — not wrapped in any 'Legate.fail:' framing" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      begin
        interp.eval(%(Legate.fail("exact wording, please")))
        fail "expected Legate::FatalSignal to propagate"
      rescue ex : Legate::FatalSignal
        ex.kind.should eq :aborted
        ex.message.should eq "exact wording, please"
      end
    end

    it "propagates past rescue Exception => e — same unrescuability as every other fatal signal (§9.2)" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      expect_raises(Legate::FatalSignal, /nope/) do
        interp.eval(<<-RUBY)
        begin
          Legate.fail("nope")
        rescue Exception => e
          "swallowed"
        end
        RUBY
      end
    end

    it "propagates past a bare rescue with no class filter too" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      expect_raises(Legate::FatalSignal, /nope/) do
        interp.eval(<<-RUBY)
        begin
          Legate.fail("nope")
        rescue
          "swallowed"
        end
        RUBY
      end
    end

    it "needs no grant at all — works under Grants.deny_all, same as every ambient verb" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      expect_raises(Legate::FatalSignal) do
        interp.eval(%(Legate.fail("still works with nothing granted")))
      end
    end

    it "raises ArgumentError (R040) when message is missing — rescuable, unlike the abort itself" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.fail
        "no error"
      rescue ArgumentError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when message isn't a String — rescuable, unlike the abort itself" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.fail(42)
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "logs no audit record — ambient verbs are not authorized against, per broker.cr" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      expect_raises(Legate::FatalSignal) do
        interp.eval(%(Legate.fail("boom")))
      end
      interp.broker.audit_log.records.should be_empty
    end
  end
end
