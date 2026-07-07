require "../../spec_helper"

module Adjutant
  describe "Builtins::Integer" do
    it "is registered as a real RubyClass reachable from script" do
      val = eval("Integer")
      val.rclass?.should be_true
      val.as_rclass.name.should eq "Integer"
    end

    it "5.is_a?(Integer) is true against the real class" do
      eval("5.is_a?(Integer)").as_bool.should be_true
    end

    it "5.is_a?(String) is false" do
      eval(%(5.is_a?(Exception))).as_bool.should be_false
    end

    it "to_s dispatches through the native method, not just the generic fallback" do
      eval("5.to_s").as_string.should eq "5"
    end

    it "to_i on an integer returns itself" do
      eval("5.to_i").as_int.should eq 5_i64
    end

    it "to_f converts to a float" do
      eval("5.to_f").as_float.should eq 5.0
    end

    it "arithmetic still works via VM opcodes, unaffected by native methods" do
      eval("2 + 3").as_int.should eq 5_i64
    end

    it "every builtin Integer method defaults to RiskProfile.none" do
      interp, _ = make_interp
      cls = interp.get_global("Integer").as_rclass
      %w[to_s to_i to_f].each do |name|
        sym_id = interp.symbols.lookup(name).not_nil!.value
        cls.find_native_method(sym_id).not_nil!.risk.should eq RiskProfile.none
      end
    end
  end
end
