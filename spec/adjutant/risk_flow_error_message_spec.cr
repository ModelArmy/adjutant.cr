require "../spec_helper"

module Adjutant
  # An interpreter with flow tracking and two natives returning values
  # labelled High: `t_int` (7) and `t_str` ("a b").
  private def self.error_labels_interp : Interpreter
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

  # The message of the error `source` raises, as a Value, so its label
  # can be read.
  private def self.error_message_value(source : String) : Value
    error_labels_interp.eval("begin\n#{source}\n:missed\nrescue => e\ne.message\nend")
  end

  # `source` if the message of the error it raises isn't labelled High,
  # with the message, or the error if it raised past the rescue; nil if
  # the message carries the label.
  private def self.error_unlabelled_message(source : String) : String?
    message = error_message_value(source)
    "#{source} (message #{message.inspect})" unless message.label.try(&.sensitivity) == Sensitivity::High
  rescue ex : Exception
    "#{source} (raised #{ex.class}: #{ex.message})"
  end

  # The sources among `sources` whose error's message isn't labelled
  # High. Empty when every message carries the label.
  private def self.error_unlabelled_messages(sources : Enumerable(String)) : Array(String)
    sources.compact_map { |source| error_unlabelled_message(source) }
  end

  describe "an error message quoting a labelled value" do
    it "carries the label from an index operation's operands" do
      sources = {
        "s = t_str\ns[0] = \"x\"",
        "[1, 2][t_int - 20, 1] = 3",
        "[1][0, t_int - 20] = 2",
        "[1, 2][(t_int - 20)..0] = 3",
      }
      error_unlabelled_messages(sources).should be_empty
    end

    it "carries the label from a native's inputs" do
      sources = {
        "5.to_s(t_int + 30)",
        "(t_int / 0.0).to_i",
      }
      error_unlabelled_messages(sources).should be_empty
    end

    it "carries the label of the value it names" do
      sources = {
        "x = t_str\nx::Foo",
        "def f(a: 1)\n  a\nend\nf(**{t_str => 1})",
        "/\#{t_str}(/",
      }
      error_unlabelled_messages(sources).should be_empty
    end

    describe "naming an unknown keyword made from a labelled value" do
      it "carries the label for a script method, a native and a class without initialize" do
        sources = {
          "def connect(host: 1)\n  host\nend\nconnect(**{t_str.to_sym => 1})",
          %("ab".upcase(**{t_str.to_sym => 1})),
          "class Plain\nend\nPlain.new(**{t_str.to_sym => 1})",
        }
        error_unlabelled_messages(sources).should be_empty
      end

      it "carries the label through a keyword rest splatted on" do
        src = <<-RUBY
        def open_socket(port: 1)
          port
        end

        def connect(**opts)
          open_socket(**opts)
        end
        connect(**{t_str.to_sym => 1})
        RUBY
        error_unlabelled_messages({src}).should be_empty
      end

      it "carries the label through a keyword rest that bare super forwards" do
        src = <<-RUBY
        class Base
          def go(port: 1)
            port
          end
        end

        class Child < Base
          def go(**opts)
            super
          end
        end
        Child.new.go(**{t_str.to_sym => 1})
        RUBY
        error_unlabelled_messages({src}).should be_empty
      end

      it "stays unlabelled for a name from a Hash with nothing labelled" do
        error_message_value("def connect(host: 1)\n  host\nend\nconnect(**{nope: 1})").label.should be_nil
      end
    end

    it "stays unlabelled when nothing it was built from is labelled" do
      error_message_value("[1, 2][-9, 1] = 3").label.should be_nil
      error_message_value("5.to_s(37)").label.should be_nil
    end

    it "stays unlabelled for a script's own error raised in a block over labelled data" do
      error_message_value(%([t_int].each { |item| raise "plain" })).label.should be_nil
    end
  end
end
