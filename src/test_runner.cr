require "colorize"

require "./adjutant"
require "./testing/assert_module"

# Test scripts runner for Adjutant.
#
# Runs each .rb file in spec/scripts/ (or given scripts path) through the interpreter
# using the AssertModule API (matching mruby's test conventions, so mruby test files
# can be borrowed and pruned to what Adjutant supports).
#
# Reports results in a format consistent with `crystal spec`.
# Run with: crystal run spec/script_runner.cr
# Exit code: 0 if all assertions pass, 1 otherwise.
module Testing
  record FileResult,
    path : String,
    mod : AssertModule,
    error : String?,
    cause : Exception? = nil

  class Runner
    @scripts_dir : String

    def initialize(@scripts_dir); end

    def run : Int32
      files = Dir.glob(File.join(@scripts_dir, "**", "*.rb")).sort
      if files.empty?
        puts "No script specs found in #{@scripts_dir}"
        return 0
      end

      results = files.map { |file| run_file(file) }
      puts
      print_summary(results)

      any_failed = results.any? { |result| result.error || result.mod.failed_count > 0 }
      any_failed ? 1 : 0
    end

    private def run_file(path : String) : FileResult
      short = path.sub(@scripts_dir + "/", "")
      ef = Adjutant::TestEffectHandler.new
      limits = Adjutant::ExecutionLimits.new(instruction_limit: 500_000_u64, call_depth_limit: 256)
      interp = Adjutant::Interpreter.new(effect: ef, limits: limits)
      mod = AssertModule.new
      interp.modules.register(mod)

      error = nil
      cause = nil
      begin
        File.open(path) { |io| interp.eval(io, path) }
      rescue e : Adjutant::ParseError
        error = "parse error: #{e.line}:#{e.column}: #{e.message}"
        cause = e
      rescue e : Adjutant::CompileError
        error = "compile error: #{e.line}:#{e.column}: #{e.message}"
        cause = e
      rescue e : Adjutant::RuntimeError
        error = "runtime error: #{e.line}: #{e.message}"
        cause = e
      end

      mod.results.each do |result|
        print(result.passed ? ".".colorize(:green) : "F".colorize(:light_red))
      end
      print "E".colorize(:yellow) if error

      FileResult.new(short, mod, error, cause)
    end

    def print_summary(results : Array(FileResult))
      puts
      results.each do |result|
        line = case cause = result.cause
               when Adjutant::CompileError, Adjutant::ParseError, Adjutant::RuntimeError
                 cause.line
               else
                 "??"
               end
        if err = result.error
          puts "ERROR #{result.path}:#{line}".colorize(:yellow), "  #{err}"
        end
        if cause = result.cause
          puts "  cause: #{cause.inspect_with_backtrace}"
          puts
        end
        result.mod.results.each do |test|
          next if test.passed
          puts "FAIL #{result.path}:#{test.line} #{test.description}".colorize(:light_red)
          puts "  #{test.message}" if test.message
          if exc = test.cause
            puts "  cause: #{exc.inspect_with_backtrace}"
          end
          puts
        end
      end

      total_passed = results.sum(&.mod.passed_count)
      total_failed = results.sum(&.mod.failed_count)
      total_errors = results.count(&.error)
      total = total_passed + total_failed

      status = (total_failed > 0 || total_errors > 0) ? :red : :green
      puts "Script specs: #{total} assertions, #{total_passed} passed, #{total_failed} failed, #{total_errors} files errored".colorize(status).bold
      puts "Files: #{results.size}"
    end
  end
end

# main -------
USAGE = <<-TEXT
Usage: test_runner [--help] [SCRIPTS_PATH]
  Run all scripts in the SCRIPTS_PATH folder
  Searches in './spec/scripts' if SCRIPTS_PATH not specified
TEXT

scripts_dir = ARGV.first? || File.join("spec/scripts")
if Dir.exists?(scripts_dir)
  exit Testing::Runner.new(scripts_dir).run
else
  STDERR.puts "ERROR: No such path: #{scripts_dir}".colorize(:red).bold
  STDERR.puts "", USAGE
end
