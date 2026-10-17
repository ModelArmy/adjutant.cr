require "../spec_helper"

module Adjutant
  # The risk walker's findings for `delete_fn`, a native whose profile
  # deletes files, wherever `source` calls it.
  private def self.nested_call_findings(source : String) : Array(RiskFinding)
    interp, _ = make_interp
    risk = RiskProfile.new(effects: Set{Effect::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error)
    interp.modules.register("delete_fn") do |i|
      i.define_native("delete_fn", risk: risk) { |_| Value.nil_value }
    end
    interp.modules.require("delete_fn", interp)
    tree = RiskWalker.new(interp).walk_body(Parser.new(source).parse)
    RiskAggregator.all_findings(tree).select(&.profile.effects.includes?(Effect::DeletesFiles))
  end

  # The findings for `source`, failing the example if there are none.
  private def self.nested_call_reported(source : String) : Array(RiskFinding)
    findings = nested_call_findings(source)
    fail "not reported: #{source.inspect}" if findings.empty?
    findings
  end

  describe "RiskWalker on a call inside another expression" do
    it "reports one that always runs as certain" do
      {
        "x = delete_fn() + 1",
        "x = delete_fn() || 1",
        "x = !delete_fn()",
        "x = delete_fn() ? 1 : 2",
        %(s = "a\#{delete_fn()}b"),
        %(r = /a\#{delete_fn()}/),
        "r = 1..delete_fn()",
        "x = [1, 2][delete_fn()]",
        "x = delete_fn()[0]",
        "h = {}\nh[delete_fn()] ||= 1",
        "h = {}\nh[delete_fn()] += 1",
        "if delete_fn()\n  1\nend",
        "unless delete_fn()\n  1\nend",
        "case delete_fn()\nwhen 1 then 2\nend",
        "x = 1 if delete_fn()",
        "for x in delete_fn()\n  x\nend",
      }.each do |source|
        findings = nested_call_reported(source)
        fail "reported as conditional: #{source.inspect}" unless findings.all?(&.branch_path.empty?)
      end
    end

    it "reports one that may not run as conditional" do
      {
        "flag = false\nflag || delete_fn()",
        "flag = true\nflag && delete_fn()",
        "flag = true\nflag ? delete_fn() : 2",
        "flag = false\nif flag\n  1\nelsif delete_fn()\n  2\nend",
      }.each do |source|
        findings = nested_call_reported(source)
        fail "reported as certain: #{source.inspect}" if findings.any?(&.branch_path.empty?)
      end
    end

    it "reports a loop's condition as repeated" do
      {
        "while delete_fn()\n  1\nend",
        "until delete_fn()\n  1\nend",
        "x = 1 while delete_fn()",
      }.each do |source|
        findings = nested_call_reported(source)
        fail "not reported as repeated: #{source.inspect}" unless findings.all?(&.iterated?)
      end
    end

    it "reports one in a `when` condition" do
      nested_call_reported("case 1\nwhen delete_fn() then 2\nend")
    end

    it "reports one in a value a method or block hands back" do
      nested_call_reported("def f\n  return delete_fn()\nend\nf")
      nested_call_reported("[1].map { |x| next delete_fn() }")
      nested_call_reported("[1].each { |x| break delete_fn() }")
    end

    it "reports one in `yield`'s arguments" do
      nested_call_reported("def g\n  yield delete_fn()\nend\ng { |v| v }")
    end

    it "reports one in a parameter's default value" do
      nested_call_reported("def h(x = delete_fn())\n  x\nend\nh")
    end
  end
end
