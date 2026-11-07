require "../../spec_helper"

module Adjutant
  # `expr`'s result as `inspect` prints it, run after `setup`.
  private def self.exception_message_of(expr : String, setup : String = "") : String
    eval("#{setup}\n(#{expr}).inspect").as_string
  end

  # A StandardError subclass, `Loud`, whose `to_s` is "loud".
  private def self.loud_error : String
    <<-RUBY
    class Loud < StandardError
      def to_s
        "loud"
      end
    end
    RUBY
  end

  # An interpreter with flow tracking and two natives returning values
  # labelled High: `t_int` (7) and `t_str` ("a b").
  private def self.exception_labels_interp : Interpreter
    interp = Interpreter.new(
      policy: Policy.new(RiskFlowPolicy.reject_all),
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      effect: TestEffectHandler.new,
      risk_flow_tracking: true,
    )
    label = RiskFlowLabel.of(ProvenanceKind::File, "/secret", Sensitivity::High)
    interp.define_native("t_int") { |_| Value.int(7_i64, label) }
    interp.define_native("t_str") { |_| Value.string("a b", label) }
    interp
  end

  # `source` if its result isn't labelled High, noting the error it
  # raised if it raised one; nil if the result carries the label.
  private def self.exception_unlabelled_result(source : String) : String?
    label = exception_labels_interp.eval(source).label
    source unless label.try(&.sensitivity) == Sensitivity::High
  rescue ex : Exception
    "#{source} (raised #{ex.class}: #{ex.message})"
  end

  # The sources among `sources` whose result isn't labelled High. Empty
  # when every result carries the label.
  private def self.exception_unlabelled(sources : Enumerable(String)) : Array(String)
    sources.compact_map { |source| exception_unlabelled_result(source) }
  end

  # `source` run inside a `begin`, then `read` of the error it raises.
  private def self.rescued(source : String, read : String) : String
    "begin\n#{source}\nrescue => e\ne.#{read}\nend"
  end

  describe "`Exception#message`, as MRI's exc_message and exc_to_s" do
    describe "returns to_s" do
      it "so a subclass's own to_s is its message" do
        exception_message_of(%(Loud.new("quiet").message), loud_error).should eq %("loud")
      end

      it "for an exception raised and rescued" do
        src = <<-RUBY
        #{loud_error}
        begin
          raise Loud, "quiet"
        rescue => e
          e.message.inspect
        end
        RUBY
        eval(src).as_string.should eq %("loud")
      end
    end

    describe "with a nil message, is the class name" do
      it "for new" do
        exception_message_of("ArgumentError.new(nil).message").should eq %("ArgumentError")
        exception_message_of("ArgumentError.new(nil).to_s").should eq %("ArgumentError")
      end

      it "for raise with a class" do
        src = <<-RUBY
        detail = nil
        begin
          raise ArgumentError, detail
        rescue => e
          e.message.inspect
        end
        RUBY
        eval(src).as_string.should eq %("ArgumentError")
      end

      it "for raise with an exception object" do
        src = <<-RUBY
        original = ArgumentError.new("bad")
        begin
          raise original, nil
        rescue => e
          e.message.inspect
        end
        RUBY
        eval(src).as_string.should eq %("ArgumentError")
      end

      it "for a script subclass passing nil to super" do
        setup = <<-RUBY
        class Wrapped < StandardError
          def initialize(detail)
            super(detail)
          end
        end
        RUBY
        exception_message_of("Wrapped.new(nil).message", setup).should eq %("Wrapped")
      end
    end

    it "is the to_s of a message that isn't a String" do
      exception_message_of("ArgumentError.new(5).message").should eq %("5")
    end

    it "keeps the risk-flow label of the message raise was given" do
      sources = {
        rescued("raise t_str", "message"),
        rescued("raise ArgumentError, t_str", "message"),
        rescued("raise ArgumentError, t_int", "message"),
        rescued(%(raise ArgumentError.new("a"), t_str), "message"),
        rescued("raise ArgumentError, t_str", "to_s"),
        rescued("raise ArgumentError, t_str", "inspect"),
        "ArgumentError.new(t_str).message",
      }
      exception_unlabelled(sources).should be_empty
    end
  end

  describe "`Exception#inspect`, as MRI's exc_inspect" do
    it "is the class and message" do
      eval(%(ArgumentError.new("bad").inspect)).as_string.should eq "#<ArgumentError: bad>"
      eval("ArgumentError.new(nil).inspect").as_string.should eq "#<ArgumentError: ArgumentError>"
    end

    it "is the class name alone for an empty message" do
      eval(%(ArgumentError.new("").inspect)).as_string.should eq "ArgumentError"
    end

    it "inspects a message holding a newline" do
      eval(%(ArgumentError.new("a\\nb").inspect)).as_string.should eq %(#<ArgumentError:"a\\nb">)
    end

    it "uses a subclass's own to_s" do
      eval("#{loud_error}\nLoud.new.inspect").as_string.should eq "#<Loud: loud>"
    end
  end
end
