require "../src/adjutant"

# This is a sample module
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
  end
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

interp = Adjutant::Interpreter.new(effect: effect, limits: limits)

# Register capabilities the script is allowed to use.
# Scripts access these exclusively via `require`.
interp.modules.register(SampleModule.new)

# Run a script from a file.
begin
  File.open(script_file) do |io|
    result = interp.eval(io, script_file)
    puts "Result: #{result}"
  end
rescue e : Adjutant::RuntimeError
  STDERR.puts "Runtime error: #{e.filename}:#{e.line}: #{e.message}"
rescue e : Adjutant::ParseError
  STDERR.puts "Parse error: #{script_file}:#{e.line}:#{e.column}: #{e.message}"
end

# Inspect what the script wrote to stdout.
puts effect.stdout
