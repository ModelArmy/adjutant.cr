require "../src/adjutant"

# This sample registers a few native functions with real risk profiles,
# so a script exercising them gets meaningful (non-Unknown) risk tags
# in the assessment below.
class RiskySampleModule < Adjutant::ScriptModule
  def name : String
    "sample"
  end

  def load(interp : Adjutant::Interpreter) : Nil
    interp.define_native("puts_args") { |args, blk| Adjutant::Value.nil_value }

    interp.define_native("delete_file",
      risk: Adjutant::RiskProfile.new(
        tags: Set{Adjutant::RiskTag::DeletesFiles},
        reversible: Adjutant::Reversibility::No,
        severity: Adjutant::Severity::Error,
      )) { |args| Adjutant::Value.nil_value }

    interp.define_native("fetch_url",
      risk: Adjutant::RiskProfile.new(
        tags: Set{Adjutant::RiskTag::NetworkEgress},
        severity: Adjutant::Severity::Warning,
      )) { |args| Adjutant::Value.string("") }
  end
end

USAGE = "Usage: assess_script FILE\n\nParse a script and print its static risk assessment, without running it."

script_file = ARGV.first?.try(&.strip)
abort(USAGE) if script_file.nil? || script_file.blank?

effect = Adjutant::TestEffectHandler.new
interp = Adjutant::Interpreter.new(effect: effect)
interp.modules.register(RiskySampleModule.new)
# Registering makes the module's native functions known to the
# interpreter (and thus to RiskWalker) without running any script code.
interp.modules.require("sample", interp)

body =
  begin
    File.open(script_file) { |io| Adjutant::Parser.new(io.gets_to_end, script_file).parse }
  rescue e : Adjutant::ParseError
    abort("Parse error: #{script_file}:#{e.line}:#{e.column}: #{e.message}")
  end

walker = Adjutant::RiskWalker.new(interp)
tree = walker.walk_body(body)

summary = Adjutant::RiskAggregator.summarize(tree)
findings = Adjutant::RiskAggregator.all_findings(tree)

puts "=== Risk assessment: #{script_file} ==="
puts
puts "Worst case: #{summary.severity} / reversible=#{summary.reversible}"
puts "Tags: #{summary.tags.empty? ? "none" : summary.tags.join(", ")}"
puts "Path: #{summary.path.join(" -> ")}" unless summary.path.empty?
puts

puts "All findings (#{findings.size}):"
findings.each do |f|
  branch = f.branch_path.empty? ? "" : " [#{f.branch_path.join(" > ")}]"
  loop_marker = f.iterated? ? " (iterated)" : ""
  tags = f.profile.tags.empty? ? "none" : f.profile.tags.join(", ")
  puts "  line #{f.line}: #{f.description}#{branch}#{loop_marker} — #{f.profile.severity}, tags: #{tags}"
end
