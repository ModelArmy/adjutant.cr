require "../../spec_helper"

module Adjutant
  # The class and message of what `expr` raises, run after `setup`, as
  # `inspect` prints them.
  private def self.raised_by(expr : String, setup : String = "") : String
    eval("#{setup}\nbegin\n#{expr}\n:missed\nrescue Exception => e\n[e.class, e.message].inspect\nend").as_string
  end

  describe "`raise`, as MRI's make_exception" do
    describe "with what it accepts" do
      it "raises a RuntimeError with a lone String as its message" do
        raised_by(%(raise "boom")).should eq %([RuntimeError, "boom"])
      end

      it "raises an instance of an exception class, with the message that follows" do
        raised_by("raise ArgumentError").should eq %([ArgumentError, "ArgumentError"])
        raised_by(%(raise ArgumentError, "bad")).should eq %([ArgumentError, "bad"])
      end

      it "raises an exception object as it is" do
        src = <<-RUBY
        original = ArgumentError.new("bad")
        begin
          raise original
        rescue => e
          e.equal?(original)
        end
        RUBY
        eval(src).as_bool.should be_true
      end

      it "raises a copy of an exception object carrying the message that follows" do
        src = <<-RUBY
        original = ArgumentError.new("bad")
        begin
          raise original, "worse"
        rescue => e
          [e.class, e.message, original.message, e.equal?(original)].inspect
        end
        RUBY
        eval(src).as_string.should eq %([ArgumentError, "worse", "bad", false])
      end

      it "keeps a copied exception object's own attributes" do
        src = <<-RUBY
        class Coded < StandardError
          def initialize(message, code)
            super(message)
            @code = code
          end

          def code
            @code
          end
        end
        begin
          raise Coded.new("bad", 7), "worse"
        rescue Coded => e
          [e.message, e.code].inspect
        end
        RUBY
        eval(src).as_string.should eq %(["worse", 7])
      end
    end

    describe "raises TypeError, \"exception class/object expected\"" do
      it "for a value that is neither an exception nor a String" do
        {"raise nil", "raise 42", "raise :boom", "raise [1]", "raise Object.new"}.each do |expr|
          raised_by(expr).should eq %([TypeError, "exception class/object expected"])
        end
      end

      it "for a class or module that isn't an exception" do
        {"raise String", %(raise String, "x"), "raise Comparable"}.each do |expr|
          raised_by(expr).should eq %([TypeError, "exception class/object expected"])
        end
      end

      it "for a String followed by more arguments" do
        raised_by(%(raise "boom", "more")).should eq %([TypeError, "exception class/object expected"])
      end
    end
  end
end
