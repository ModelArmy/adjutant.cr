require "../src/adjutant"

# One executable, two roles (research/WORKER_DESIGN.md). Started with
# `Adjutant::Worker::ARGUMENT`, it is a worker: it serves one request
# from its Supervisor and exits on this line. Started any other way, it
# is the host below, and starts itself again as a worker for each
# request, so a fault in Adjutant costs that worker, not the host.
Adjutant::Worker.main(ARGV)

USAGE = <<-TEXT
  Usage: worker_host SCRIPT

  Assesses SCRIPT, then runs it if you agree, each in a worker process:
  this executable started again with #{Adjutant::Worker::ARGUMENT}.
  Reads are granted under SCRIPT's directory; any path containing
  "secret" is asked about first. Try samples/scripts/worker/read_secret.rb.
  TEXT

# Grants reads under `dir`, and asks before reading anything whose path
# contains "secret".
def policy_for(dir : String) : String
  <<-YAML
    grants:
      read: { roots: [#{dir.to_json}] }
    risk_flow:
      patterns:
        - { kind: file, type: regex, pattern: "secret", priority: 10, sensitivity: high }
      rules:
        - { authority: read, sensitivity: high, action: ask }
      default: reject
    YAML
end

def confirm?(question : String) : Bool
  print "#{question} [y/N]: "
  STDIN.gets.try(&.strip.downcase) == "y"
end

# Builds the prompt from the Ask's description. The words are the
# host's; Adjutant supplies only the data.
def approve?(request : Adjutant::Protocol::DecisionRequest) : Adjutant::RiskFlowDecision
  puts
  puts "=== The script asks ==="
  puts "Call: #{request.call_name}#{request.subject.try { |subject| " #{subject}" }}  (#{request.filename}:#{request.line})"
  puts "Risk: #{request.risk.severity}, reversible: #{request.risk.reversible}"
  request.matches.each do |match|
    puts "  because #{match.tag.kind} #{match.tag.origin} is #{match.tag.sensitivity}"
  end
  confirm?("Allow it?") ? Adjutant::RiskFlowDecision::Allow : Adjutant::RiskFlowDecision::Reject
end

def log(event : Adjutant::Supervisor::Log) : Nil
  STDERR.puts "[#{event.severity}] #{event.source}: #{event.message}"
end

# Explains an outcome only the Supervisor can report, and exits.
def give_up(outcome : Adjutant::Supervisor::Crashed | Adjutant::Supervisor::TimedOut | Adjutant::Supervisor::Violated,
            observed : Adjutant::Supervisor::Observed) : NoReturn
  reason =
    case outcome
    in Adjutant::Supervisor::Crashed  then "the worker ended without finishing"
    in Adjutant::Supervisor::TimedOut then "the worker ran out of time (#{outcome.clock})"
    in Adjutant::Supervisor::Violated then "the worker broke the protocol: #{outcome.reason}"
    end
  STDERR.puts reason
  STDERR.puts "Its stderr ended with:\n#{observed.stderr}" unless observed.stderr.empty?
  unless observed.held_open.empty?
    held = observed.held_open.map(&.to_s.downcase).join(" and ")
    STDERR.puts "A process the worker started held its #{held} open, and may still be running."
  end
  exit 1
end

script = ARGV.first?
abort(USAGE) unless script && File.file?(script)
source = File.read(script)
policy = policy_for(File.realpath(File.dirname(script)))

# 1. Assess, in one worker.
assessment = Adjutant::Supervisor.spawn.assess(source, policy, filename: script, ceiling: 30.seconds) do |event|
  log(event) if event.is_a?(Adjutant::Supervisor::Log)
end
case outcome = assessment.outcome
in Adjutant::Supervisor::Assessed
  puts "=== Assessment: #{script} ==="
  puts "Worst case: #{outcome.summary.severity}, reversible: #{outcome.summary.reversible}"
  puts "Effects: #{outcome.summary.effects.empty? ? "none" : outcome.summary.effects.join(", ")}"
  outcome.findings.each { |finding| puts "  line #{finding.line}: #{finding.description}" }
in Adjutant::Supervisor::Raised
  abort(outcome.rendered)
in Adjutant::Supervisor::Crashed  then give_up(outcome, assessment.observed)
in Adjutant::Supervisor::TimedOut then give_up(outcome, assessment.observed)
in Adjutant::Supervisor::Violated then give_up(outcome, assessment.observed)
end
exit unless confirm?("Run it?")

# 2. Run, in another.
puts "=== Running: #{script} ==="
report = Adjutant::Supervisor.spawn.run(source, policy, filename: script, ceiling: 10.minutes) do |event|
  case event
  in Adjutant::Supervisor::Output
    print event.text
    STDOUT.flush
  in Adjutant::Supervisor::Log then log(event)
  in Adjutant::Supervisor::Ask then event.answer(approve?(event.request))
  end
end
case outcome = report.outcome
in Adjutant::Supervisor::Completed then puts "Result: #{outcome.value}#{outcome.truncated? ? " [truncated]" : ""}"
in Adjutant::Supervisor::Raised    then STDERR.puts outcome.rendered
in Adjutant::Supervisor::Fatal     then STDERR.puts "Stopped (#{outcome.signal}): #{outcome.message}"
in Adjutant::Supervisor::Crashed   then give_up(outcome, report.observed)
in Adjutant::Supervisor::TimedOut  then give_up(outcome, report.observed)
in Adjutant::Supervisor::Violated  then give_up(outcome, report.observed)
end

# What the Supervisor saw for itself, then what the worker reported.
observed = report.observed
puts
puts "Observed: #{observed.elapsed.total_milliseconds.round(1)} ms, #{observed.asks} ask(s), " \
     "#{observed.output_bytes} bytes of output, exit #{observed.exit_status.try(&.exit_code?) || "?"}"
puts "Reported by the worker: #{report.audit.size} audit record(s)"
report.audit.each do |entry|
  puts "  #{entry.decision} #{entry.verb} #{entry.subject}"
end
