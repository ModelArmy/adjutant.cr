require "../spec_helper"

module Adjutant
  describe RiskProfile do
    it "none has no tags, is reversible, and is informational" do
      profile = RiskProfile.none
      profile.tags.should be_empty
      profile.reversible.should eq Reversibility::Yes
      profile.severity.should eq Severity::Info
    end

    it "default initializer matches .none" do
      RiskProfile.new.should eq RiskProfile.none
    end

    it "allows a tagged profile with elevated severity and reversibility" do
      profile = RiskProfile.new(
        tags: Set{RiskTag::DeletesFiles, RiskTag::Recursive},
        reversible: Reversibility::No,
        severity: Severity::Error,
      )
      profile.tags.should eq Set{RiskTag::DeletesFiles, RiskTag::Recursive}
      profile.reversible.should eq Reversibility::No
      profile.severity.should eq Severity::Error
    end

    it "raises when empty tags are paired with non-default reversibility" do
      expect_raises(ArgumentError, /no tags must have reversible: Yes/) do
        RiskProfile.new(reversible: Reversibility::No)
      end
    end

    it "raises when empty tags are paired with non-default severity" do
      expect_raises(ArgumentError, /no tags must have reversible: Yes/) do
        RiskProfile.new(severity: Severity::Warning)
      end
    end

    it "raises when reversible is Depends without a note" do
      expect_raises(ArgumentError, /note is required when reversible is Depends/) do
        RiskProfile.new(tags: Set{RiskTag::WritesFiles}, reversible: Reversibility::Depends)
      end
    end

    it "allows reversible: Depends when a note is provided" do
      profile = RiskProfile.new(
        tags: Set{RiskTag::WritesFiles},
        reversible: Reversibility::Depends,
        note: "reversible only if --backup is passed",
      )
      profile.reversible.should eq Reversibility::Depends
      profile.note.should eq "reversible only if --backup is passed"
    end
  end

  describe NativeCallable do
    it "defaults to RiskProfile.none when no risk is given" do
      callable = NativeCallable.new(NativeFunc.new { |args, _, _| args.first })
      callable.risk.should eq RiskProfile.none
    end

    it "carries an explicit risk profile" do
      risk = RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning)
      callable = NativeCallable.new(NativeFunc.new { |args, _, _| args.first }, risk)
      callable.risk.should eq risk
    end

    it "calling delegates to the wrapped func" do
      interp = Interpreter.new
      interp.modules.register("test/callable") do |i|
        i.define_native("double") { |args| Value.int(args.first.as_int * 2) }
      end
      interp.modules.require("test/callable", interp)
      interp.eval("double(21)").as_int.should eq 42_i64
    end
  end

  describe "Interpreter#define_native with risk" do
    it "attaches a risk profile to a native function" do
      interp = Interpreter.new
      risk = RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
      interp.define_native("dangerous_delete", risk: risk) { |_| Value.nil_value }
      sym_id = interp.symbols.lookup("dangerous_delete").not_nil!.value
      interp.native_callable(sym_id).not_nil!.risk.should eq risk
    end

    it "defaults new native functions to RiskProfile.none" do
      interp = Interpreter.new
      interp.define_native("harmless") { |_| Value.nil_value }
      sym_id = interp.symbols.lookup("harmless").not_nil!.value
      interp.native_callable(sym_id).not_nil!.risk.should eq RiskProfile.none
    end

    it "still executes correctly through the VM when a risk profile is attached" do
      interp = Interpreter.new
      risk = RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, severity: Severity::Warning)
      interp.define_native("fetch_thing", risk: risk) { |args| Value.string("fetched:#{args.first.as_string}") }
      interp.eval(%(fetch_thing("url"))).as_string.should eq "fetched:url"
    end
  end
end
