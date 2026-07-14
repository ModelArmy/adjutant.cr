require "../src/adjutant"

# This is a sample module demonstrating information flow control (risk
# flow) — its native functions label their return values with real
# provenance and consult the interpreter's own risk_flow_policy for
# sensitivity, the way a real File IO / HTTP module would. See
# DEVELOPMENT.md's "Information flow control (risk flow)" section and
# research/IFC_DESIGN.md for the design this implements.
class SampleModule < Adjutant::ScriptModule
  def name : String
    "sample"
  end

  def load(interp : Adjutant::Interpreter) : Nil
    interp.define_native("puts_args") do |args, blk|
      puts "--- puts_args:"
      args.each_with_index do |arg, i|
        puts "  #{i}: #{arg.raw.inspect}"
      end
      puts "  ->: #{blk.inspect}" if blk

      Adjutant::Value.nil_value
    end

    interp.define_native("times") do |args, blk, ncc|
      if (count = args.first?.try(&.as_int?)) && blk
        count.times { |i| ncc.invoke(blk, [Adjutant::Value.int(i)]) }
        Adjutant::Value.int(count)
      else
        Adjutant::Value.nil_value
      end
    end

    # Reads a "file" (simulated — no real filesystem access in this
    # sample) and labels the returned content with the path's
    # provenance and the sensitivity risk_flow_policy assigns it. This
    # is the pattern a real File IO module follows: consult
    # `interp.risk_flow_policy.sensitivity_for(...)` once, at the point
    # a value enters the script, then attach a RiskFlowLabel carrying
    # that sensitivity so it can propagate through everything the
    # script does with the value afterward.
    interp.define_native("read_file") do |args|
      path = args.first.as_string
      sensitivity = interp.risk_flow_policy.sensitivity_for(Adjutant::ProvenanceKind::File, path)
      label = Adjutant::RiskFlowLabel.of(Adjutant::ProvenanceKind::File, path, sensitivity)
      Adjutant::Value.string("contents of #{path}", label)
    end

    # Simulated network fetch — same labeling pattern as read_file,
    # but for a Host-kind origin.
    interp.define_native("fetch_url") do |args|
      url = args.first.as_string
      sensitivity = interp.risk_flow_policy.sensitivity_for(Adjutant::ProvenanceKind::Host, url)
      label = Adjutant::RiskFlowLabel.of(Adjutant::ProvenanceKind::Host, url, sensitivity)
      Adjutant::Value.string("response from #{url}", label)
    end

    # Deletes a "file" (simulated) — the risky argument is the path
    # itself. `declare_sensitivity` is what actually protects this
    # call: it consults risk_flow_policy on the path's literal content
    # directly, so a script that never touched read_file at all (e.g.
    # `delete_file("/etc/passwd")` with no intermediate variable) is
    # still caught — the automatic, label-driven check in
    # VM#call_native has no way to see danger in an argument nothing
    # ever labeled. See DEVELOPMENT.md's "Writing a ScriptModule"
    # section and research/IFC_DESIGN.md's enforcement notes for why
    # this is a real, separate gap dynamic IFC alone can't close: it
    # only ever tracks taint that flowed *through* a labeling call, not
    # the literal content of a value the script wrote directly.
    interp.define_native("delete_file",
      risk: Adjutant::RiskProfile.new(
        tags: Set{Adjutant::RiskTag::DeletesFiles},
        reversible: Adjutant::Reversibility::No,
        severity: Adjutant::Severity::Error,
      )) do |args, _blk, ncc|
      path = args.first.as_string
      ncc.declare_sensitivity(Adjutant::RiskTag::DeletesFiles, Adjutant::ProvenanceKind::File, path)
      puts "  [simulated] deleted #{path}"
      Adjutant::Value.bool(true)
    end

    # Posts data externally — the risky argument is the data being
    # sent, not the url. Unlike delete_file's path argument, `data`
    # here is free-form content (not a well-known identifier like a
    # path or hostname), so there's no meaningful sensitivity_for
    # pattern to declare against it directly — this relies entirely on
    # the inherited RiskFlowLabel a value like `secrets` already
    # carries when it came from read_file/fetch_url, caught by
    # VM#call_native's automatic label-driven check. A native function
    # should only call declare_sensitivity on arguments whose literal
    # content is itself a meaningful, policy-matchable identifier (see
    # delete_file above) — not every risky argument needs it.
    interp.define_native("post_data",
      risk: Adjutant::RiskProfile.new(
        tags: Set{Adjutant::RiskTag::NetworkEgress},
        severity: Adjutant::Severity::Warning,
      )) do |args|
      url = args.first.as_string
      data = args[1]?.try(&.as_string) || ""
      puts "  [simulated] posted #{data.size} bytes to #{url}"
      Adjutant::Value.bool(true)
    end
  end
end

# A real IFC policy, loaded via RiskFlowPolicy.from_json — the same way
# an embedding agent would load one from a config file. Written inline
# here (rather than a separate file on disk) purely so the whole policy
# is visible as part of this sample; Adjutant itself never reads a
# policy path off disk (see DEVELOPMENT.md).
SAMPLE_POLICY_JSON = <<-JSON
{
  "sensitivity_patterns": [
    { "kind": "File", "pattern": "/etc/passwd", "priority": 10, "sensitivity": "High" },
    { "kind": "File", "pattern_type": "regex", "pattern": "^/etc/", "priority": 0, "sensitivity": "Elevated" },
    { "kind": "File", "pattern": "/tmp/scratch.txt", "priority": 10, "sensitivity": "None" },
    { "kind": "Host", "pattern_type": "regex", "pattern": "internal$", "priority": 0, "sensitivity": "None" },
    { "kind": "Host", "pattern_type": "regex", "pattern": ".*", "priority": -10, "sensitivity": "Elevated" }
  ],
  "risk_flow_rules": [
    { "tag": "DeletesFiles", "sensitivity": "Elevated", "action": "Ask" },
    { "tag": "DeletesFiles", "sensitivity": "High", "action": "Reject" },
    { "tag": "NetworkEgress", "sensitivity": "Elevated", "action": "Ask" },
    { "tag": "NetworkEgress", "sensitivity": "High", "action": "Ask" }
  ]
}
JSON

# Builds a human-readable prompt from a RiskFlowDecisionRequest and asks
# the user via STDIN. This is deliberately NOT part of Adjutant's own
# API — Adjutant never generates end-user-facing text (an embedder may
# need this in any language, any format, any UI, not just an English
# terminal prompt), it only supplies the structured data
# (RiskFlowDecisionRequest) needed to build one. Rendering the prompt
# is entirely this sample's job, same as it would be any real agent's.
def prompt_for_risk_flow_decision(request : Adjutant::RiskFlowDecisionRequest) : Adjutant::RiskFlowDecision
  puts
  puts "=== Risk flow approval requested ==="
  puts "Call: #{request.call_name}  (#{request.filename}:#{request.line})"
  puts "Risk: #{request.risk.severity}, reversible=#{request.risk.reversible}, tags: #{request.risk.tags.join(", ")}"
  puts "Reasons (worst first):"
  request.matches.each do |match|
    rule_desc = match.rule.try { |rule| "#{rule.tag} x #{rule.sensitivity} -> #{rule.action}" } || "reject_all policy"
    puts "  - #{match.tag.kind}:#{match.tag.origin} (#{match.tag.sensitivity}) matched #{rule_desc}"
  end
  puts

  print "Allow this call? [y/N]: "
  answer = STDIN.gets.try(&.strip.downcase)
  answer == "y" ? Adjutant::RiskFlowDecision::Allow : Adjutant::RiskFlowDecision::Reject
end

USAGE = "Usage: run_script FILE\n\nOpen, compile and interpret the Ruby-ish script"

script_file = ARGV.first?.try(&.strip)
abort(USAGE) if script_file.nil? || script_file.blank?

# Define the physical effect boundary — what the script can write and read.
effect = Adjutant::TestEffectHandler.new # or your own EffectHandler subclass

# Set execution limits (optional).
limits = Adjutant::ExecutionLimits.new(
  instruction_limit: 100_000_u64,
  call_depth_limit: 256
)

# Both risk_flow_policy and on_risk_flow_decision are required — there
# is no default that means "skip risk assessment." See
# DEVELOPMENT.md's "Information flow control (risk flow)" section.
interp = Adjutant::Interpreter.new(
  risk_flow_policy: Adjutant::RiskFlowPolicy.from_json(SAMPLE_POLICY_JSON),
  on_risk_flow_decision: ->(req : Adjutant::RiskFlowDecisionRequest) { prompt_for_risk_flow_decision(req) },
  effect: effect,
  limits: limits,
)

# Register capabilities the script is allowed to use.
# Scripts access these exclusively via `require`.
interp.modules.register(SampleModule.new)
# Registering makes the module's native functions known to the
# interpreter (and thus to RiskWalker) without running any script code
# — needed for the static assessment pass below to see real RiskTags
# instead of Unknown ones.
interp.modules.require("sample", interp)

script_source = File.read(script_file)

# Static risk assessment (SAST-style): walks the parsed AST WITHOUT
# running it, so it can flag a risky call (`delete_file`'s DeletesFiles
# tag, say) purely from the call shape — regardless of whether any
# argument is a literal, a variable, or the result of another call.
# This is what catches risk_flow_declared_literal.rb-style scripts
# structurally, independent of what any particular argument's value
# turns out to be at runtime. See assess_script.cr for the same
# analysis as a standalone tool, and DEVELOPMENT.md for why Adjutant
# has both a static and a dynamic (risk flow / IFC) layer — they catch
# different things, and this sample demonstrates both together on the
# same script rather than treating them as alternatives.
begin
  body = Adjutant::Parser.new(script_source, script_file).parse
  walker = Adjutant::RiskWalker.new(interp)
  tree = walker.walk_body(body)
  summary = Adjutant::RiskAggregator.summarize(tree)

  puts "=== Static risk assessment: #{script_file} ==="
  puts "Worst case: #{summary.severity} / reversible=#{summary.reversible}"
  puts "Tags: #{summary.tags.empty? ? "none" : summary.tags.join(", ")}"
  puts
rescue e : Adjutant::ParseError
  abort("Parse error: #{script_file}:#{e.line}:#{e.column}: #{e.message}")
end

# Now actually run the script — this is where dynamic risk flow (IFC)
# enforcement kicks in, via VM#call_native's automatic label-driven
# check and SampleModule's explicit declare_sensitivity calls.
puts "=== Running: #{script_file} ==="
begin
  result = interp.eval(script_source, script_file)
  puts "Result: #{result}"
rescue e : Adjutant::RuntimeError
  STDERR.puts "Runtime error: #{e.filename}:#{e.line}: #{e.message}"
end

# Inspect what the script wrote to stdout.
puts effect.stdout
