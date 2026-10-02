require "../../spec_helper"

module Adjutant
  # Runs `setup`, then returns `expr`'s `inspect`, or the class of the
  # error it raised.
  private def self.object_model_outcome(setup : String, expr : String) : String
    eval(<<-RUBY).as_string
      #{setup}
      begin
        (#{expr}).inspect
      rescue NoMethodError
        "NoMethodError"
      rescue NameError
        "NameError"
      rescue TypeError
        "TypeError"
      rescue ArgumentError
        "ArgumentError"
      end
      RUBY
  end

  describe "undefined methods" do
    it "raise NoMethodError with a receiver or arguments" do
      object_model_outcome("", "5.nope").should eq "NoMethodError"
      object_model_outcome("", "nil.nope").should eq "NoMethodError"
      object_model_outcome("", "self.nope").should eq "NoMethodError"
      object_model_outcome("class Foo; end", "Foo.nope").should eq "NoMethodError"
      object_model_outcome("", "nope(1)").should eq "NoMethodError"
    end

    it "raise NameError for a bare name that could be a variable" do
      object_model_outcome("", "nope").should eq "NameError"
    end

    it "name the method and receiver as Ruby does" do
      eval(%(begin\n  5.nope\nrescue NoMethodError => e\n  e.message\nend)).as_string
        .should eq "undefined method `nope` for an instance of Integer"
    end
  end

  describe "operators without a method" do
    it "raise NoMethodError on nil or an object without the operator" do
      object_model_outcome("", "nil + 1").should eq "NoMethodError"
      object_model_outcome("", "nil - 1").should eq "NoMethodError"
      object_model_outcome("", "nil * 2").should eq "NoMethodError"
      object_model_outcome("", "nil < 1").should eq "NoMethodError"
      object_model_outcome("", "Object.new + 1").should eq "NoMethodError"
    end

    it "raise TypeError when the receiver has the operator and rejects the argument" do
      object_model_outcome("", %("a" + 1)).should eq "TypeError"
      object_model_outcome("", %(1 + "a")).should eq "TypeError"
    end
  end

  describe "is_a? and Class#===" do
    setup = "module A; end\nmodule B; include A; end\nclass C; include B; end"

    it "see a module included by an included module" do
      object_model_outcome(setup, "C.new.is_a?(A)").should eq "true"
      object_model_outcome(setup, "A === C.new").should eq "true"
    end
  end

  describe "include and extend" do
    it "raise TypeError for anything but a module" do
      {"include K", "extend K", "include 5"}.each do |line|
        eval("class K; end\nbegin\n  class L\n    #{line}\n  end\n  :ok\nrescue TypeError\n  :type_error\nend")
          .as_sym.name.should eq "type_error"
      end
    end
  end

  describe "equal?" do
    it "compares identity: the same String or Array, not an equal one" do
      object_model_outcome(%(s = "a"), "s.equal?(s)").should eq "true"
      object_model_outcome("", %("ab".equal?("a" + "b"))).should eq "false"
      object_model_outcome("a = [1]", "[a.equal?(a), a.equal?([1])]").should eq "[true, false]"
    end

    it "is true for equal immediates" do
      object_model_outcome("", "[1.equal?(1), :a.equal?(:a), nil.equal?(nil)]").should eq "[true, true, true]"
    end
  end

  describe "superclass" do
    it "raises NoMethodError on anything but a class" do
      object_model_outcome("", "5.superclass").should eq "NoMethodError"
    end
  end

  describe "respond_to?" do
    it "is true for methods every object has" do
      object_model_outcome("", "[5.respond_to?(:to_s), Object.new.respond_to?(:inspect), nil.respond_to?(:nil?)]")
        .should eq "[true, true, true]"
    end

    it "is true for operators" do
      object_model_outcome("", "[5.respond_to?(:+), [1].respond_to?(:+), 1.5.respond_to?(:<)]")
        .should eq "[true, true, true]"
    end

    it "is false for private Kernel methods and unknown names" do
      object_model_outcome("", "[5.respond_to?(:puts), 5.respond_to?(:nope)]").should eq "[false, false]"
    end
  end

  describe "dup and clone" do
    it "copy a Time, Regexp or MatchData with its state" do
      object_model_outcome("", "Time.at(0).dup.to_i").should eq "0"
      object_model_outcome("", "/ab/.clone.source").should eq %("ab")
      object_model_outcome("", %(/b/.match("abc").dup[0])).should eq %("b")
    end

    it "copy an Array or Hash shallowly" do
      object_model_outcome("a = [1, [2]]\nb = a.dup\nb.push(3)", "[a.size, b.size, a[1].equal?(b[1])]")
        .should eq "[2, 3, true]"
      object_model_outcome("h = {a: 1}\ng = h.dup\ng[:b] = 2", "[h.size, g.size]").should eq "[1, 2]"
    end

    it "return an immediate or String itself" do
      object_model_outcome("", %([5.dup, nil.dup, :a.dup, "a".dup])).should eq %([5, nil, :a, "a"])
    end
  end

  describe "an Exception subclass's initialize" do
    setup = <<-RUBY
      class Oops < StandardError
        def initialize(n)
          super("got \#{n}")
        end
      end
      class Http < StandardError
        attr_reader :status
        def initialize(status)
          @status = status
          super("HTTP \#{status}")
        end
      end
      RUBY

    it "runs for new" do
      object_model_outcome(setup, "Oops.new(1).message").should eq %("got 1")
      object_model_outcome(setup + "\ne = Http.new(404)", "[e.status, e.message]").should eq %([404, "HTTP 404"])
    end

    it "runs for raise with a class and an argument" do
      object_model_outcome(setup, "begin\n  raise Oops, 3\nrescue Oops => e\n  e.message\nend").should eq %("got 3")
    end

    it "checks new's arity against initialize" do
      object_model_outcome(setup, "Oops.new").should eq "ArgumentError"
    end
  end

  describe "Exception.new without a script initialize" do
    it "takes at most a message" do
      object_model_outcome("", %(StandardError.new("a", "b"))).should eq "ArgumentError"
    end
  end
end
