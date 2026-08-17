require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "Exception" do
      # NOTE: `.new`'s own closure-capture bug (see the "Exception.new
      # / subclass.new" describe block, below, for the fix and its
      # regression coverage) is why every case in the OTHER describe
      # blocks below still constructs via `raise ClassName, message;
      # rescue e; e` rather than `ClassName.new(message)` directly —
      # kept that way even after the fix landed, since it exercises
      # the genuinely separate `make_error_object` (vm.cr) path,
      # which was never in question.

      describe "Exception.new / subclass.new" do
        # Found while writing the OTHER describe blocks below,
        # unrelated to `to_s`/`inspect` but directly affecting whether
        # THOSE tests could be trusted if written against `.new`
        # directly: `define_exception_class`'s (and, identically,
        # `define_name_error_class`'s) own singleton `new`
        # (builtins/exceptions.cr) closed over `cls` from ITS OWN
        # definition-time scope, never the actual receiver — so
        # `TypeError.new("msg")` built an `Exception`-classed object,
        # not a `TypeError`-classed one, and `NoMethodError.new("msg")`
        # (inheriting `NameError`'s singleton `new`, having none of
        # its own) built a `NameError`-classed one. Fixed by reading
        # `args.first.as_rclass` (the actual receiver) instead.

        it "TypeError.new produces a TypeError-classed instance, not Exception" do
          eval("TypeError.new(\"msg\").class.to_s").as_string.should eq "TypeError"
        end

        it "NoMethodError.new (inheriting NameError's singleton `new`, having none of its own) produces a NoMethodError-classed instance, not NameError" do
          eval("NoMethodError.new(\"msg\").class.to_s").as_string.should eq "NoMethodError"
        end

        it "a script's own subclass with no .new of its own also builds correctly, inheriting Exception's singleton new" do
          eval(<<-RUBY).as_string.should eq "MyError"
          class MyError < StandardError
          end
          MyError.new("msg").class.to_s
          RUBY
        end

        it "THE ACTUAL FAILURE MODE this caused: an exception built via .new and then raised is now catchable by its own class — it wasn't before, since its real class was the base Exception, not the subclass rescue was filtering for" do
          eval(<<-RUBY).as_string.should eq "caught"
          begin
            raise TypeError.new("msg")
          rescue TypeError
            "caught"
          end
          RUBY
        end

        it "NameError's own subclass-inherited new is ALSO catchable by its real class now" do
          eval(<<-RUBY).as_string.should eq "caught"
          begin
            raise NoMethodError.new("msg")
          rescue NoMethodError
            "caught"
          end
          RUBY
        end

        it "the built instance's message is unaffected by the fix" do
          eval(%(TypeError.new("msg").message)).as_string.should eq "msg"
        end

        it "NameError's own subclass-inherited new still sets the name ivar correctly too" do
          eval(<<-RUBY).as_string.should eq "foo"
          e = NoMethodError.new("msg", "foo")
          e.name
          RUBY
        end
      end

      describe "#to_s" do
        it "returns the message when one was given" do
          eval(<<-RUBY).as_string.should eq "boom"
          begin
            raise RuntimeError, "boom"
          rescue e
            e.to_s
          end
          RUBY
        end

        it "falls back to the class name when no message was given" do
          eval(<<-RUBY).as_string.should eq "RuntimeError"
          begin
            raise RuntimeError
          rescue e
            e.to_s
          end
          RUBY
        end

        it "a subclass reports its OWN class name in the fallback, not \"Exception\" (the defining class)" do
          eval(<<-RUBY).as_string.should eq "TypeError"
          begin
            raise TypeError
          rescue e
            e.to_s
          end
          RUBY
        end
      end

      describe "#inspect" do
        # Before this, Exception had no `inspect` at all — it fell
        # through to Object's own default #inspect, listing ivars:
        # #<RuntimeError @message="boom">, not real Ruby's actual
        # #<RuntimeError: boom> format.
        it "renders as #<ClassName: message> when a message was given" do
          eval(<<-RUBY).as_string.should eq "#<RuntimeError: boom>"
          begin
            raise RuntimeError, "boom"
          rescue e
            e.inspect
          end
          RUBY
        end

        it "renders as #<ClassName: ClassName> when no message was given, matching #to_s's own fallback" do
          eval(<<-RUBY).as_string.should eq "#<RuntimeError: RuntimeError>"
          begin
            raise RuntimeError
          rescue e
            e.inspect
          end
          RUBY
        end

        it "a subclass reports its own class name on both sides of the colon" do
          eval(<<-RUBY).as_string.should eq "#<TypeError: nope>"
          begin
            raise TypeError, "nope"
          rescue e
            e.inspect
          end
          RUBY
        end

        it "a script's own subclass overriding to_s has that override reflected in inspect too, via real dispatch" do
          result = eval(<<-RUBY)
          class MyError < StandardError
            def to_s
              "custom message"
            end
          end
          begin
            raise MyError
          rescue e
            e.inspect
          end
          RUBY
          result.as_string.should eq "#<MyError: custom message>"
        end

        it "inspect is inherited by every subclass, registered once on the base Exception class" do
          eval(<<-RUBY).as_string.should eq "#<ArgumentError: bad arg>"
          begin
            raise ArgumentError, "bad arg"
          rescue e
            e.inspect
          end
          RUBY
        end
      end

      describe "#message" do
        it "returns the message when one was given" do
          eval(<<-RUBY).as_string.should eq "boom"
          begin
            raise RuntimeError, "boom"
          rescue e
            e.message
          end
          RUBY
        end
      end
    end
  end
end
