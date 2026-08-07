require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "require via VFS" do
      it "loads a script file from the VFS and its def is callable afterward" do
        # A required file's DEF should be visible afterward, same as
        # real Ruby (require executes the file and its method/class/
        # constant definitions persist in the requiring context). A
        # required file's own top-level LOCAL variables should NOT
        # persist — require's VFS fallback runs the file via a
        # genuinely separate eval call (see
        # Interpreter#require_module), and a top-level local is now
        # correctly scoped to its own eval call (see the 2026-07-15
        # scoping fix) — matching real Ruby, where a required file's
        # locals were never visible to the requiring context either.
        interp, ef = make_interp
        ef.add_file("greet.rb", %(def greeting; "hello from vfs"; end))
        interp.eval(%(require "greet.rb"))
        interp.eval("greeting").as_string.should eq "hello from vfs"
      end

      it "does NOT leak a required file's own top-level local variables" do
        interp, ef = make_interp
        ef.add_file("greet.rb", %(x = "hello from vfs"))
        interp.eval(%(require "greet.rb"))
        expect_raises(Adjutant::RuntimeError, /undefined method or variable `x`/) do
          interp.eval("x")
        end
      end

      it "raises when file not found" do
        interp, _ = make_interp
        expect_raises(RuntimeError, /cannot load/) do
          interp.eval(%(require "missing.rb"))
        end
      end

      it "loads a registered script module" do
        interp, _ = make_interp
        interp.modules.register("agent/math") do |i|
          i.define_native("double") { |args| Value.int(args.first.as_int * 2) }
        end
        interp.eval(%(require "agent/math"\ndouble(5))).as_int.should eq 10_i64
      end

      it "loads each module only once" do
        count = 0
        interp, _ = make_interp
        interp.modules.register("once") { |_| count += 1 }
        interp.eval(%(require "once"\nrequire "once"))
        count.should eq 1
      end
    end
  end
end
