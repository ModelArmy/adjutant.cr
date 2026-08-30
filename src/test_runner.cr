require "colorize"
require "sync/exclusive"
require "wait_group"

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

    # A script directory that wants real `Legate.*` access — rather
    # than the blanket `Grants.deny_all` every OTHER script under
    # `spec/scripts/` still gets, completely unchanged — drops a
    # sibling file by this name, in LEGATE.md §7's OWN real config
    # shape (`Legate::Grants.from_yaml`, reused as-is rather than
    # inventing a second parallel config format), in the SAME
    # directory as the script(s) that need it. Not any ancestor
    # directory — different subfolders can carry different policies
    # over time (the actual reason for a sibling-file convention
    # rather than one shared config) without one leaking into
    # another. Added 2026-08-26 to unblock `spec/scripts/legate/`
    # example/regression scripts.
    POLICY_FILE_NAME = "_policy.yaml"

    def run : Int32
      files = Dir.glob(File.join(@scripts_dir, "**", "*.rb")).sort
      if files.empty?
        puts "No script specs found in #{@scripts_dir}"
        return 0
      end

      # Run each file in parallel
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
      interp = Adjutant::Interpreter.new(
        risk_flow_policy: Adjutant::RiskFlowPolicy.reject_all,
        grants: grants_for(path),
        on_risk_flow_decision: ->(_req : Adjutant::RiskFlowDecisionRequest) { Adjutant::RiskFlowDecision::Reject },
        effect: ef,
        limits: limits,
      )
      mod = AssertModule.new
      interp.modules.register(mod)

      error = nil
      cause = nil
      begin
        # `__FILE__` (parser.cr's `KwFile` case) resolves to exactly
        # this SECOND `path` argument, verbatim — normalized to `/`
        # via `Path#to_posix` here (a no-op on Linux/macOS) because
        # `Dir.glob` above returns `\`-joined paths on Windows,
        # matching `list.cr`'s own established Windows-portability
        # fix earlier this session. Without this, any script using
        # `__FILE__` and splitting on `/` (a script has no OTHER way
        # to derive its own directory — there's no ambient File IO
        # module, SCOPE.md's own noted gap) would silently get the
        # wrong answer specifically on a Windows runner. `File.open`
        # just below still uses the ORIGINAL, native-separator `path`
        # — real filesystem access needs the OS's own separator
        # convention, only the SCRIPT-VISIBLE `__FILE__` value needs
        # normalizing.
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
      end

      # Exclusive access to STDOUT
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

      raw = Adjutant::Legate::Grants.from_file(policy_path)
      # `Grants.from_yaml` stores each root string exactly as written
      # in the YAML — a RELATIVE root like `read_roots: [fixtures]`
      # would otherwise resolve against wherever the `crystal spec`/
      # `ops test` PROCESS happens to be invoked from, not against
      # `_policy.yaml`'s own directory. That's exactly the class of
      # bug `list.cr`'s own Windows path-separator fix (earlier this
      # session) was about — fragile across machines/CI/OS — so every
      # path-like entry (roots, exec binaries; NOT `net_hosts`/
      # `ambient_env`, which aren't filesystem paths at all) is
      # expanded HERE, against `dir`, before building the real Grants
      # a script actually runs under.
      Adjutant::Legate::Grants.new(
        read_roots: raw.read_roots.map { |root| File.expand_path(root, dir) },
        write_roots: raw.write_roots.map { |root| File.expand_path(root, dir) },
        delete_roots: raw.delete_roots.map { |root| File.expand_path(root, dir) },
        net_rules: raw.net_rules,
        net_methods: raw.net_methods,
        exec_binaries: raw.exec_binaries.map { |root| File.expand_path(root, dir) },
        ambient_env: raw.ambient_env,
        ambient_now: raw.ambient_now,
        limits: raw.limits,
      )
    end

    # Prefers a rendered diagnostic (source line + carets) when the
    # raise site has been migrated, and falls back to the old
    # one-line form otherwise. Plain text rather than Markdown: this
    # goes to a terminal, and the fences would be noise.
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
      # RuntimeError records a filename and line but no column, unlike
      # the parse/compile errors — position fidelity differs by phase
      # in the fallback exactly as it does in a rendered diagnostic.
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
