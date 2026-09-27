require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "require via VFS" do
      it "loads a script file from the VFS and its def is callable afterward" do
        # A required file's DEF should be visible afterward, same as
        # real Ruby (require executes the file and its method/class/
        # constant definitions persist in the requiring context). A
        # required file's own top-level LOCAL variables should NOT
        # persist: the file runs with a top-level frame of its own
        # (VM#run_required), as in Ruby, where a required file's locals
        # are never visible to the requiring context.
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

      it "runs a VFS file once, returning true and then false, as Ruby's require does" do
        interp, ef = make_interp
        ef.add_file("hello.rb", %(puts "loaded"))
        # `require` parses only as a statement, so its value is read
        # as each script's last.
        interp.eval(%(require "hello.rb")).truthy?.should be_true
        interp.eval(%(require "hello.rb")).truthy?.should be_false
        ef.stdout.should eq "loaded\n"
      end

      it "returns false for a registered module already loaded" do
        interp, _ = make_interp
        interp.modules.register("once") { |_| }
        interp.eval(%(require "once")).truthy?.should be_true
        interp.eval(%(require "once")).truthy?.should be_false
      end

      it "returns false for a file that requires itself, rather than recursing" do
        interp, ef = make_interp
        ef.add_file("self.rb", %(require "self.rb"\nputs "once"))
        interp.eval(%(require "self.rb"))
        ef.stdout.should eq "once\n"
      end

      it "tries a file again after it failed to load" do
        interp, ef = make_interp
        ef.add_file("bad.rb", %(raise "boom"))
        2.times do
          expect_raises(RuntimeError, /boom/) { interp.eval(%(require "bad.rb")) }
        end
      end

      # A required file runs in the requiring script's VM, so its frames
      # count toward that script's limits; in a VM of its own, each
      # side here stays under the limit.
      it "counts a required file's call depth toward the requiring script's" do
        limits = ExecutionLimits.new(call_depth_limit: 24)
        interp, ef = make_interp(limits)
        ef.add_file("deep.rb", "def deep(n)\n  n == 0 ? 0 : deep(n - 1)\nend\ndeep(15)")
        error = expect_raises(RuntimeError) do
          interp.eval(<<-RUBY)
            def down(n)
              if n == 0
                require "deep.rb"
              else
                down(n - 1)
              end
            end
            down(15)
          RUBY
        end
        error.diagnostic.not_nil!.code.should eq "L002"
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
