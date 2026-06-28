require "../src/adjutant"

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

interp = Adjutant::Interpreter.new(effect: effect, limits: limits)

# Register capabilities the script is allowed to use.
# Scripts access these exclusively via `require`.
interp.modules.register("agent/io") do |i|
  i.define_native("read_input") { |_args| Adjutant::Value.string(gets || "") }
end

# Run a script from a file.
begin
  File.open(script_file) do |io|
    result = interp.eval(io, script_file)
    puts "Result: #{result}"
  end
rescue e : Adjutant::RuntimeError
  STDERR.puts "Script error: #{e.message}"
rescue e : Adjutant::ParseError
  STDERR.puts "Parse error: #{e.message}"
end

# Inspect what the script wrote to stdout.
puts effect.stdout
