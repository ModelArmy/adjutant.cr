require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "literals" do
      it "evaluates nil" do
        eval("nil").null?.should be_true
      end

      it "evaluates true" do
        eval("true").as_bool.should be_true
      end

      it "evaluates false" do
        eval("false").as_bool.should be_false
      end

      it "evaluates an integer" do
        eval("42").as_int.should eq 42_i64
      end

      it "evaluates a float" do
        eval("3.14").as_float.should be_close(3.14, 1e-10)
      end

      it "evaluates a string" do
        eval(%("hello")).as_string.should eq "hello"
      end

      it "evaluates a symbol" do
        v = eval(":ok")
        v.symbol?.should be_true
        v.as_sym.name.should eq "ok"
      end

      it "evaluates an array literal" do
        v = eval("[1, 2, 3]")
        v.array?.should be_true
        v.as_array.size.should eq 3
      end

      it "evaluates a hash literal" do
        v = eval(%({ "a" => 1 }))
        v.hash?.should be_true
        v.as_hash.size.should eq 1
      end

      it "evaluates symbol-shorthand hash literal syntax ({k: v}) to real " \
         "symbol keys, indexable the same as :key => val would produce" do
        v = eval("{ a: 1, b: 2 }")
        v.hash?.should be_true
        v.as_hash.size.should eq 2
        keys = v.as_hash.keys.map(&.as_sym.name)
        keys.should eq ["a", "b"]
      end

      it "a symbol-shorthand key and its explicit :key => val equivalent " \
         "produce the same symbol name and value at runtime" do
        shorthand = eval("{ a: 1 }").as_hash
        explicit = eval("{ :a => 1 }").as_hash
        shorthand.size.should eq explicit.size
        s_key, s_val = shorthand.keys.first, shorthand.values.first
        e_key, e_val = explicit.keys.first, explicit.values.first
        s_key.as_sym.name.should eq e_key.as_sym.name
        s_val.as_int.should eq e_val.as_int
      end

      it "the option-hash shape (retries: 3, timeout: 10) parses and " \
         "evaluates end to end — the concrete motivating case for this " \
         "feature, not just the minimal {k: v} shape" do
        v = eval("{ retries: 3, timeout: 10 }")
        h = v.as_hash
        h.size.should eq 2
        pairs = [] of {String, Int64}
        h.each { |k, val| pairs << {k.as_sym.name, val.as_int} }
        pairs.to_set.should eq Set{ {"retries", 3_i64}, {"timeout", 10_i64} }
      end
    end

    describe "string interpolation" do
      it "interpolates an integer" do
        eval(%("value: \#{42}")).as_string.should eq "value: 42"
      end

      it "interpolates a variable" do
        eval(%(x = "world"\n"hello \#{x}")).as_string.should eq "hello world"
      end
    end

    describe "__FILE__ and __LINE__" do
      it "__FILE__ evaluates to the filename eval was given" do
        interp, _ = make_interp
        interp.eval("__FILE__", "reading.rb").as_string.should eq "reading.rb"
      end

      it "__LINE__ evaluates to its own line, not line 1, when not on the first line" do
        interp, _ = make_interp
        interp.eval("x = 1\ny = 2\n__LINE__").as_int.should eq 3_i64
      end

      it "both can be combined, e.g. for a diagnostic message a script builds itself" do
        interp, _ = make_interp
        interp.eval(%("\#{__FILE__}:\#{__LINE__}"), "diag.rb").as_string.should eq "diag.rb:1"
      end
    end
  end
end
