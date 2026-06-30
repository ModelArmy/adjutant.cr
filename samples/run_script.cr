require "../src/adjutant"

class AssertError < RuntimeError; end

# The `assert` module provides assertion test methods
# which I hope to use to run more source tests.
class AssertModule < Adjutant::ScriptModule
  def name : String
    "assert"
  end

  def load(interp : Adjutant::Interpreter) : Nil
    interp.define_native("p_args") do |args, blk|
      puts "#inspect_call:"
      args.each_with_index do |arg, i|
        puts "  #{i}: #{arg.raw.inspect}"
      end
      puts "  ->: #{blk.inspect}"

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

    interp.define_native("assert_equal") do |args|
      if (a = args[0]?) && (b = args[1]?)
        assert_equal(a, b)
      else
        raise AssertError.new("assert_equal: Expected 2 args, received #{args.size}")
      end
    end

    interp.define_native("assert_result_is") do |args, blk, ncc|
      if expected_result = args[0]?
        if blk
          assert_expect(ncc, blk, expected_result)
        else
          raise AssertError.new("assert_expect: Expected block to yield to")
        end
      else
        raise AssertError.new("assert_expect: Expected 1 args, received #{args.size}")
      end
    end
  end

  # ---- implementations

  private def assert_expect(ncc : Adjutant::NativeCallContext,
                            proc : Adjutant::ScriptProc,
                            expected : Adjutant::Value)
    result = ncc.invoke(proc, [] of Adjutant::Value)
    assert_equal(result, expected)
    result
  end

  private def assert_equal(a : Adjutant::Value, b : Adjutant::Value)
    equal = case
            when a.null? && b.null?     then true
            when a.bool? && b.bool?     then a.as_bool == b.as_bool
            when a.int? && b.int?       then a.as_int == b.as_int
            when a.float? && b.float?   then a.as_float == b.as_float
            when a.int? && b.float?     then a.as_int.to_f64 == b.as_float
            when a.float? && b.int?     then a.as_float == b.as_int.to_f64
            when a.string? && b.string? then a.as_string == b.as_string
            when a.symbol? && b.symbol? then a.as_sym == b.as_sym
            else                             false
            end
    if equal
      Adjutant::Value.bool(true)
    else
      raise AssertError.new("assert_equal: #{a.inspect} != #{b.inspect} ")
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
interp.modules.register(AssertModule.new)

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
rescue e : AssertError
  STDERR.puts "Assertion failed: #{e.message}"
end

# Inspect what the script wrote to stdout.
puts effect.stdout
