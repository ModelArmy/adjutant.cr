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

    it "stays unlabelled when nothing it was built from is labelled" do
      error_message_value("[1, 2][-9, 1] = 3").label.should be_nil
      error_message_value("5.to_s(37)").label.should be_nil
    end

    it "stays unlabelled for a script's own error raised in a block over labelled data" do
      error_message_value(%([t_int].each { |item| raise "plain" })).label.should be_nil
    end
  end
end
