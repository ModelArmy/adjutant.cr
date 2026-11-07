require "../spec_helper"

module Adjutant
  # An interpreter with flow tracking and three natives returning values
  # labelled High from `/secret`: `t_int` (7), `t_float` (2.5) and
  # `t_str` ("Hello world 42").
  private def self.native_labels_interp : Interpreter
    interp = Interpreter.new(
      policy: Policy.new(RiskFlowPolicy.reject_all),
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      effect: TestEffectHandler.new,
      risk_flow_tracking: true,
    )
    label = RiskFlowLabel.of(ProvenanceKind::File, "/secret", Sensitivity::High)
    interp.define_native("t_int") { |_| Value.int(7_i64, label) }
    interp.define_native("t_float") { |_| Value.float(2.5, label) }
    interp.define_native("t_str") { |_| Value.string("Hello world 42", label) }
    interp
  end

  # `source` if its result isn't labelled High, noting the error it
  # raised if it raised one; nil if the result carries the label.
  private def self.unlabelled_result(source : String) : String?
    label = native_labels_interp.eval(source).label
    source unless label.try(&.sensitivity) == Sensitivity::High
  rescue ex : Exception
    "#{source} (raised #{ex.class}: #{ex.message})"
  end

  # The sources among `sources` whose result isn't labelled High. Empty
  # when every result carries the label.
  private def self.unlabelled_results(sources : Enumerable(String)) : Array(String)
    sources.compact_map { |source| unlabelled_result(source) }
  end

  describe "a native method's result, from a labelled input" do
    it "carries the label from an Integer receiver" do
      unlabelled_results({
        "t_int.to_s", "t_int.to_s(2)", "t_int.inspect", "t_int.to_i", "t_int.to_f",
        "t_int.succ", "t_int.next", "t_int.abs", "t_int.even?", "t_int.odd?", "t_int.zero?",
        "t_int.ceil", "t_int.floor", "t_int.round", "t_int.truncate", "t_int.round(-1)",
        "t_int ** 2", "t_int.times { }", "t_int.between?(1, 9)", "t_int.clamp(1, 5)",
      }).should eq [] of String
    end

    it "carries the label from a Float receiver" do
      unlabelled_results({
        "t_float.to_s", "t_float.inspect", "t_float.to_i", "t_float.to_f",
        "t_float.ceil", "t_float.floor", "t_float.round", "t_float.round(1)", "t_float.truncate",
        "t_float.abs", "t_float.finite?", "t_float.infinite?", "t_float.nan?", "t_float ** 2",
      }).should eq [] of String
    end

    it "carries the label from a String receiver" do
      unlabelled_results({
        "t_str.to_s", "t_str.inspect", "t_str.to_i", "t_str.to_f", "t_str.to_sym",
        "t_str.length", "t_str.size", "t_str.empty?",
        "t_str.upcase", "t_str.downcase", "t_str.capitalize", "t_str.strip", "t_str.chomp", "t_str.reverse",
        %(t_str.include?("o")), %(t_str.start_with?("H")), %(t_str.end_with?("2")),
        %(t_str.index("o")), %(t_str.rindex("o")), %(t_str.sub("o", "0")), %(t_str.gsub("o", "0")),
        "t_str =~ /o/", "t_str[0]", "t_str[0, 2]", "t_str[0..2]",
        %(t_str.split(" ").first), "t_str.chars.first",
        "t_str.match(/(o)/)[1]", "t_str.match(/o/).pre_match",
      }).should eq [] of String
    end

    it "carries the label from a Symbol made from a labelled String" do
      unlabelled_results({"t_str.to_sym.to_s", "t_str.to_sym.inspect"}).should eq [] of String
    end

    it "carries the label from a Range with a labelled bound" do
      unlabelled_results({
        "(1..t_int).include?(3)", "(1..t_int).member?(3)", "(1..t_int).to_s", "(1..t_int).inspect",
        "(1..t_int).min", "(1..t_int).max", "(1..t_int).last", "(1..t_int).end",
        "(t_int..9).first", "(t_int..9).begin",
      }).should eq [] of String
    end

    it "carries the label from a Time made from a labelled number" do
      unlabelled_results({
        "Time.at(t_int)", "Time.at(t_int).to_i", "Time.at(t_int).to_f", "Time.at(t_int).year",
        "Time.at(t_int).sec", "Time.at(t_int).to_s", "(Time.at(0) + t_int).to_i",
      }).should eq [] of String
    end

    it "carries the label from a labelled argument" do
      unlabelled_results({
        "2 ** t_int", "3.between?(1, t_int)", "3.clamp(1, t_int)",
        "(1..10).include?(t_int)", %("Hello".include?(t_str)),
      }).should eq [] of String
    end
  end

  # Values a native yields to a block or collects into a container from
  # labelled input, and values it computes from a labelled container. A
  # plain element read (`arr.first`, `arr[0]`) is left out: it returns
  # the element, with its own label, rather than a computed value.
  describe "a value yielded, collected or computed from a labelled container" do
    it "carries the label into what it yields to a block" do
      unlabelled_results({
        "last = nil\nt_int.times { |i| last = i }\nlast",
        "last = nil\n(1..t_int).each { |i| last = i }\nlast",
        "last = nil\n(1..t_int).step(2) { |i| last = i }\nlast",
        "last = nil\nt_str.chars.each { |char| last = char }\nlast",
        "last = nil\nt_str.each_line { |line| last = line }\nlast",
      }).should eq [] of String
    end

    it "carries the label into a container it builds, and its elements" do
      unlabelled_results({
        "(1..t_int).to_a", "(1..t_int).to_a.first", "(1..t_int).to_a.last",
        %(t_str.split(" ")), "t_str.chars",
      }).should eq [] of String
    end

    it "carries a labelled Array's label into what it computes from it" do
      unlabelled_results({
        "[t_int, 2, 3].size", "[t_int, 2, 3].length", "[t_int, 2, 3].empty?",
        "[t_int, 2, 3].include?(2)", %([t_int, 2, 3].join(",")),
        "[t_int, 2, 3].min", "[t_int, 2, 3].max", "[t_int, 2, 3].inject(:+)",
        "[t_int, 2, 3].to_s", "[t_int, 2, 3].inspect",
        %(t_str.split(" ").size),
      }).should eq [] of String
    end

    it "carries a labelled Hash's label into what it computes from it" do
      unlabelled_results({
        "h = {k: t_int}\nh.size", "h = {k: t_int}\nh.length", "h = {k: t_int}\nh.empty?",
        "h = {k: t_int}\nh.key?(:k)", "h = {k: t_int}\nh.has_key?(:k)", "h = {k: t_int}\nh.include?(:k)",
        "h = {k: t_int}\nh.to_s", "h = {k: t_int}\nh.inspect",
      }).should eq [] of String
    end
  end
end
