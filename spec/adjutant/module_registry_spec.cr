require "../spec_helper"

module Adjutant
  class ConcreteTestMod < ScriptModule
    property loaded_into : Interpreter? = nil

    def name : String
      "test/concrete"
    end

    def load(interp : Interpreter) : Nil
      @loaded_into = interp
    end
  end

  describe ModuleRegistry do
    it "registers and loads a module" do
      loaded = false
      interp, _ = make_interp
      interp.modules.register("test/mod") { |_| loaded = true }
      interp.modules.require("test/mod", interp)
      loaded.should be_true
    end

    it "returns true when module is found" do
      interp, _ = make_interp
      interp.modules.register("test/mod") { |_| }
      interp.modules.require("test/mod", interp).should be_true
    end

    it "returns false when module is not found" do
      interp, _ = make_interp
      interp.modules.require("unknown", interp).should be_false
    end

    it "loads each module only once" do
      count = 0
      interp, _ = make_interp
      interp.modules.register("once") { |_| count += 1 }
      interp.modules.require("once", interp)
      interp.modules.require("once", interp)
      count.should eq 1
    end

    it "reports loaded? correctly" do
      interp, _ = make_interp
      interp.modules.register("mymod") { |_| }
      interp.modules.loaded?("mymod").should be_false
      interp.modules.require("mymod", interp)
      interp.modules.loaded?("mymod").should be_true
    end

    it "reports registered? correctly" do
      interp, _ = make_interp
      interp.modules.registered?("mymod").should be_false
      interp.modules.register("mymod") { |_| }
      interp.modules.registered?("mymod").should be_true
    end

    it "lists registered paths" do
      interp, _ = make_interp
      interp.modules.register("a") { |_| }
      interp.modules.register("b") { |_| }
      interp.modules.registered_paths.sort.should eq ["a", "b"]
    end

    it "lists loaded paths" do
      interp, _ = make_interp
      interp.modules.register("x") { |_| }
      interp.modules.register("y") { |_| }
      interp.modules.require("x", interp)
      interp.modules.loaded_paths.should eq ["x"]
    end

    it "exposes native functions via define_native" do
      interp, _ = make_interp
      interp.modules.register("math") do |i|
        i.define_native("square") { |args| Value.int(args.first.as_int ** 2) }
      end
      interp.modules.require("math", interp)
      result = interp.eval("square(7)")
      result.as_int.should eq 49_i64
    end

    it "can be used with a concrete ScriptModule subclass" do
      mod = ConcreteTestMod.new
      interp, _ = make_interp
      interp.modules.register(mod)
      interp.modules.require("test/concrete", interp)
      mod.loaded_into.should eq interp
    end
  end
end
