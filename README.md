# adjutant.cr

A Crystal shard that defines and implements a safe Ruby-like scripting interpreter for agent harnesses: with a controlled effect boundary, module capability registry, and information flow control.

> **WARNING**: This shard is a work in progress and in development until this warning is removed.

> See [DISCLOSURE](./DISCLOSURE.md) for information how AI is used by this project.

## Installation

1. Add the dependency to your `shard.yml`:

```yml
dependencies:
  adjutant:
    github: modelarmy/adjutant.cr
```

2. Run `shards install`

## Usage

The entry point is `Adjutant::Interpreter`. It owns a symbol table and globals that persist across multiple `eval` calls, making it suitable for a long-lived agent session.

```crystal
require "adjutant"

# Define the physical effect boundary — what the script can write and read.
effect = Adjutant::TestEffectHandler.new  # or your own EffectHandler subclass

# Set execution limits (optional).
limits = Adjutant::ExecutionLimits.new(
  instruction_limit: 100_000_u64,
  call_depth_limit:  256
)

interp = Adjutant::Interpreter.new(effect: effect, limits: limits)

# Register capabilities the script is allowed to use.
# Scripts access these exclusively via `require`.
interp.modules.register("agent/io") do |i|
  i.define_native("read_input") { |_args| Adjutant::Value.string(gets || "") }
end

# Run a script from a file.
begin
  File.open("script.rb") do |io|
    result = interp.eval(io, "script.rb")
    puts "Result: #{result}"
  end
rescue Adjutant::RuntimeError => e
  STDERR.puts "Script error: #{e.message}"
rescue Adjutant::ParseError => e
  STDERR.puts "Parse error: #{e.message}"
end

# Inspect what the script wrote to stdout.
puts effect.stdout
```

You can also compile without executing — useful for pre-validating LLM-generated scripts before running them:

```crystal
begin
  chunk = interp.compile(source, "script.rb")
  # chunk is an Adjutant::Chunk you can inspect or execute later
rescue Adjutant::ParseError => e
  STDERR.puts "Invalid script: #{e.message}"
end
```

Globals persist across `eval` calls on the same interpreter instance, so scripts can be evaluated incrementally across a conversation turn.

## Development

See [DEVELOPMENT.md](./DEVELOPMENT.md) for how to build, run the samples, and understand the internals.

## Contributions, by invitation!

*With apologies*, at this time contributions are *by invitation only* and limited to people I know and see often.

These are early days for _Adjutant_ and I am busy with family and work.

At this time I want to work on this at a manageable pace.
