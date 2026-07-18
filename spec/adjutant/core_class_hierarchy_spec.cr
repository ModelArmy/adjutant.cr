require "../spec_helper"

module Adjutant
  # Covers the Phase 0/1 base-types work: the Object/Class/Module core
  # hierarchy (a genuine circular dependency in real Ruby, resolved via
  # a two-pass bootstrap — see Interpreter#bootstrap_core_hierarchy),
  # every class's superclass/rclass defaulting, and the .class/is_a?/
  # kind_of?/respond_to?/equal? methods that depend on it.
  describe "Core hierarchy bootstrap (Object, Class, Module)" do
    it "Object, Class, and Module are globally reachable by name" do
      interp, _ = make_interp
      result = interp.eval("[Object.is_a?(Class), Class.is_a?(Class), Module.is_a?(Class)]")
      result.as_array.map(&.truthy?).should eq [true, true, true]
    end

    it "Class.superclass is Module" do
      interp, _ = make_interp
      result = interp.eval("Class.superclass == Module")
      result.truthy?.should be_true
    end

    it "Object.superclass is nil — the true root" do
      interp, _ = make_interp
      result = interp.eval("Object.superclass")
      result.null?.should be_true
    end

    it "Module.superclass is Object, matching real Ruby" do
      # Previously asserted nil — Module's superclass link was simply
      # never set in bootstrap_core_hierarchy (an oversight, not a
      # deliberate simplification like Object.superclass being nil
      # instead of BasicObject). Real Ruby: Class.superclass ==
      # Module, Module.superclass == Object. This gap caused a real
      # regression found in the 2026-07-16/17 root-scope work: a
      # module body's self is the module itself (a RubyClass), and
      # implicit-self dispatch for a Kernel-style native call (e.g.
      # `assert_not_nil` inside `module M; ...; end`) needs to walk
      # self.rclass's (Module's) own superclass chain up to Object —
      # broken at its very first link without this.
      interp, _ = make_interp
      result = interp.eval("Module.superclass == Object")
      result.truthy?.should be_true
    end

    it "Class.class is Class itself — the one genuinely self-referential case" do
      interp, _ = make_interp
      result = interp.eval("Class.class == Class")
      result.truthy?.should be_true
    end

    it "Object.class is Class" do
      interp, _ = make_interp
      result = interp.eval("Object.class == Class")
      result.truthy?.should be_true
    end

    it "Module.class is Class" do
      interp, _ = make_interp
      result = interp.eval("Module.class == Class")
      result.truthy?.should be_true
    end
  end

  describe "superclass/rclass defaulting for script-defined classes" do
    it "class Foo; end with no explicit superclass inherits from Object" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        Foo.superclass == Object
      RUBY
      result.truthy?.should be_true
    end

    it "class Foo < Bar still respects the explicit superclass, not Object" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Bar
        end
        class Foo < Bar
        end
        [Foo.superclass == Bar, Foo.superclass == Object]
      RUBY
      result.as_array.map(&.truthy?).should eq [true, false]
    end

    it "every script-defined class's own class is Class" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        Foo.class == Class
      RUBY
      result.truthy?.should be_true
    end

    it "a module's own class is Class, not Module — Module itself is an instance of Class" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        module M
        end
        M.class == Class
      RUBY
      result.truthy?.should be_true
    end

    it "an instance's class is the class that built it, not Class" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        Foo.new.class == Foo
      RUBY
      result.truthy?.should be_true
    end

    it "builtin classes (e.g. Integer) also default rclass to Class" do
      interp, _ = make_interp
      result = interp.eval("Integer.class == Class")
      result.truthy?.should be_true
    end

    it "builtin classes (e.g. Exception) default superclass to Object when none given" do
      interp, _ = make_interp
      result = interp.eval("Exception.superclass == Object")
      result.truthy?.should be_true
    end
  end

  describe "is_a?/kind_of? against the real ancestor chain" do
    it "an instance is_a? its own class" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        Foo.new.is_a?(Foo)
      RUBY
      result.truthy?.should be_true
    end

    it "an instance is_a? an ancestor, walking the real chain up to Object" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        Foo.new.is_a?(Object)
      RUBY
      result.truthy?.should be_true
    end

    it "a module object itself is_a? Object, walking Module's own superclass chain" do
      # Fixed as a side effect of the Module.superclass fix above —
      # is_a_target? already correctly starts from recv.rclass
      # (Module, for a module object) and walks ITS superclass chain;
      # that chain just never reached Object before, since
      # Module.superclass was nil.
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        module M
        end
        M.is_a?(Object)
      RUBY
      result.truthy?.should be_true
    end

    it "a class object itself is_a? Object too, via Class -> Module -> Object" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        Foo.is_a?(Object)
      RUBY
      result.truthy?.should be_true
    end

    it "an instance is NOT is_a? an unrelated class" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        class Bar
        end
        Foo.new.is_a?(Bar)
      RUBY
      result.falsy?.should be_true
    end

    it "kind_of? is a true alias of is_a?, not separate logic" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        f = Foo.new
        f.is_a?(Foo) == f.kind_of?(Foo)
      RUBY
      result.truthy?.should be_true
    end

    it "a builtin value is_a? its own class via builtin_class_for" do
      interp, _ = make_interp
      result = interp.eval("5.is_a?(Integer)")
      result.truthy?.should be_true
    end
  end

  describe "respond_to?" do
    it "true for a user-defined instance method" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
          def bar; 1; end
        end
        Foo.new.respond_to?(:bar)
      RUBY
      result.truthy?.should be_true
    end

    it "false for an undefined method name" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        Foo.new.respond_to?(:nope)
      RUBY
      result.falsy?.should be_true
    end

    it "true for a def self.foo singleton method, on the class receiver" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
          def self.bar; 1; end
        end
        Foo.respond_to?(:bar)
      RUBY
      result.truthy?.should be_true
    end

    it "accepts a String argument as well as a Symbol" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
          def bar; 1; end
        end
        Foo.new.respond_to?("bar")
      RUBY
      result.truthy?.should be_true
    end

    it "true for a native instance method (e.g. Integer#to_s)" do
      interp, _ = make_interp
      result = interp.eval("5.respond_to?(:to_s)")
      result.truthy?.should be_true
    end
  end

  describe "equal?" do
    it "true for the same receiver compared to itself" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
        end
        f = Foo.new
        f.equal?(f)
      RUBY
      result.truthy?.should be_true
    end

    it "true for two equal integers (documented immediate-value behavior)" do
      interp, _ = make_interp
      result = interp.eval("5.equal?(5)")
      result.truthy?.should be_true
    end

    it "false for two different instances, even with identical state" do
      interp, _ = make_interp
      result = interp.eval(<<-RUBY)
        class Foo
          def initialize(n); @n = n; end
        end
        Foo.new(1).equal?(Foo.new(1))
      RUBY
      result.falsy?.should be_true
    end
  end
end
