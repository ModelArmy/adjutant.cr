require "colorize"
require "sync/exclusive"
require "wait_group"

require "./adjutant"
require "./testing/assert_module"
require "./testing/wiretap_module"

# Runs each `.rb` script under spec/scripts/ (or the given path)
# through an Interpreter with AssertModule, whose API matches mruby's
# so mruby's test files can be borrowed. Output resembles
# `crystal spec`'s; exits 0 if every assertion passes, 1 otherwise.
module Testing
  record FileResult,
    path : String,
    mod : AssertModule,
    error : String?,
    cause : Exception? = nil

  class Runner
    @scripts_dir : String

    def initialize(@scripts_dir); end

    # A script directory that needs Legate access holds a policy file
    # of this name, in LEGATE.md §7's format, beside its scripts;
    # applies to that directory only. Scripts elsewhere run under
    # `Grants.deny_all`.
    POLICY_FILE_NAME = "_policy.yaml"

    def run : Int32
      WiretapModule.setup
      files = Dir.glob(File.join(@scripts_dir, "**", "*.rb")).sort
      if files.empty?
        puts "No script specs found in #{@scripts_dir}"
        return 0
      end

      # Runs each file in parallel.
      results = [] of FileResult
      ctx = Fiber::ExecutionContext::Parallel.new("MULTI", maximum: System.cpu_count // 2)
      sync_results = Sync::Exclusive.new(results)
      sync_stdout = Sync::Exclusive.new(STDOUT)
      wait_group = WaitGroup.new(files.size)

      files.each do |file|
        ctx.spawn do
          result = run_file(file, sync_stdout)
          sync_results.lock(&.push(result))
        ensure
          wait_group.done
        end
      end
      wait_group.wait

      puts
      print_summary(results)

      any_failed = results.any? { |result| result.error || result.mod.failed_count > 0 }
      any_failed ? 1 : 0
    end

    private def run_file(path : String, sync_io) : FileResult
      short = path.sub(@scripts_dir + "/", "")
      ef = Adjutant::TestEffectHandler.new
      limits = Adjutant::ExecutionLimits.new(instruction_limit: 500_000_u64, call_depth_limit: 256)
      mod = AssertModule.new

      error = nil
      cause = nil

      interp = begin
        Adjutant::Interpreter.new(
          risk_flow_policy: Adjutant::RiskFlowPolicy.reject_all,
          grants: grants_for(path),
          on_risk_flow_decision: ->(_req : Adjutant::RiskFlowDecisionRequest) { Adjutant::RiskFlowDecision::Reject },
          effect: ef,
          limits: limits,
        )
      rescue e : Exception
        # Anything that stops an interpreter being built becomes this
        # file's failure. An exception escaping the fiber would drop the
        # file's result from the report.
        cause = e
        error = describe_unexpected_error(e)
        nil
      end

      if interp && !error
        interp.modules.register(mod)
        interp.modules.register(WiretapModule.new)

        begin
          # `__FILE__` is this name, with `/` separators on every
          # platform, since `Dir.glob` returns `\` on Windows. The file
          # itself is opened by its native path.
          eval_filename = ::Path.new(path).to_posix.to_s
          File.open(path) { |io| interp.eval(io, eval_filename) }
        rescue e : Adjutant::ParseError
          error = describe_error(interp, e, "parse error", path)
          cause = e
        rescue e : Adjutant::CompileError
          error = describe_error(interp, e, "compile error", path)
          cause = e
        rescue e : Adjutant::RuntimeError
          error = describe_error(interp, e, "runtime error", path)
          cause = e
        rescue e : Exception
          # Anything that stops the interpreter becomes this file's
          # failure, as above.
          error = describe_unexpected_error(e)
          cause = e
        end
      end

      # Exclusive access to STDOUT.
      sync_io.lock do |stdout|
        mod.results.each do |result|
          stdout.print(result.passed ? ".".colorize(:green) : "F".colorize(:light_red))
        end
        stdout.print "E".colorize(:yellow) if error
      end

      FileResult.new(short, mod, error, cause)
    end

    private def grants_for(script_path : String) : Adjutant::Legate::Grants
      dir = File.expand_path(File.dirname(script_path))
      policy_path = File.join(dir, POLICY_FILE_NAME)
      return Adjutant::Legate::Grants.deny_all unless File.exists?(policy_path)

      raw = Adjutant::Legate::Grants.from_yaml(File.read(policy_path))
      # Relative roots are expanded against the policy file's own
      # directory, not the process's working directory. Hosts and
      # environment names aren't paths, so are left as written.
      Adjutant::Legate::Grants.new(
        read_roots: raw.read_roots.map { |root| File.expand_path(root, dir) },
        write_roots: raw.write_roots.map { |root| File.expand_path(root, dir) },
        delete_roots: raw.delete_roots.map { |root| File.expand_path(root, dir) },
        net_rules: raw.net_rules,
        net_methods: raw.net_methods,
        ambient_env: raw.ambient_env,
        limits: raw.limits,
      )
    end

    # Describes an unexpected error.
    private def describe_unexpected_error(e : Exception) : String
      kind = "unexpected_error"
      if e.is_a?(Adjutant::RuntimeError)
        "#{kind}: #{e.filename}:#{e.line}: #{e.message}"
      else
        "#{kind}: #{e.class}: #{e.message}"
      end
    end

    # A rendered diagnostic, in plain text for the terminal, when the
    # error has one; otherwise its one-line form.
    private def describe_error(interp : Adjutant::Interpreter,
                               error : Adjutant::ParseError | Adjutant::CompileError | Adjutant::RuntimeError,
                               kind : String,
                               path : String) : String
      rendered = interp.render_error(
        error,
        Adjutant::DiagnosticRenderer::Format::PlainText,
        path
      )
      return rendered if rendered
      # A RuntimeError has a line but no column.
      if error.is_a?(Adjutant::RuntimeError)
        "#{kind}: #{error.filename}:#{error.line}: #{error.message}"
      else
        "#{kind}: #{error.line}:#{error.column}: #{error.message}"
      end
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
