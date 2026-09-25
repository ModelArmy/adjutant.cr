require "../broker"
require "../match"
require "../path"
require "../exceptions"
require "../helpers"
require "../../builtins/helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.grep(pattern, paths, context: 0, limit: 10_000) ->
      # Array<Legate::Match>` (LEGATE.md §4.1): content search in
      # Crystal, so scripts needn't shell out to `rg`. `pattern` is a
      # String (a literal substring) or a Regexp. `paths` is a glob or
      # an Array of globs and plain paths, each expanded with
      # `Dir.glob`.
      module Grep
        KWARG_NAMES     = Set{"context", "limit"}
        DEFAULT_LIMIT   = 10_000
        DEFAULT_CONTEXT =      0

        # A file with a NUL in its first 8000 bytes is binary and
        # skipped (§4.1), git's heuristic.
        BINARY_SNIFF_BYTES = 8000

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          too_many = Helpers.fetch(legate, interp, "TooMany")
          match_cls = Helpers.fetch(legate, interp, "Match")
          path_cls = Helpers.fetch(legate, interp, "Path")

          # A Read sink; see read.cr.
          legate.define_native_singleton_method(
            interp.symbols.intern("grep").value,
            RiskProfile.new(effects: Set{Effect::ReadsFiles}),
            KWARG_NAMES,
            authorities: Set{Authority::Read},
          ) do |args, _blk, ncc|
            # Every argument is validated before authorizing.
            pattern = pattern_arg(args[1]?, ncc)
            context = context_of(ncc)
            limit = limit_of(ncc)

            paths_val = args[2]?
            if paths_val.nil?
              ncc.raise_error("R035", {} of String => String, "ArgumentError")
            end
            patterns, label = patterns_and_label(paths_val, ncc)
            posix_patterns = patterns.map { |raw_pattern| ::Path.new(raw_pattern).to_posix.to_s }

            # One authorization per distinct fixed-prefix directory,
            # not per pattern or per file. Every match is labelled with
            # the result, whatever the matched file's own sensitivity.
            prefixes = posix_patterns.map { |posix_pattern| Helpers.fixed_prefix(posix_pattern) }.uniq!
            prefixes.each do |prefix|
              label = RiskFlowLabel.join(label, broker.authorize_read(prefix, ncc, allow_missing: true))
            end

            matched_files = posix_patterns.flat_map { |posix_pattern| Dir.glob(posix_pattern) }.uniq!.sort!
            # Each file is also checked for containment, without an
            # audit record; one that fails is dropped.
            in_bounds = matched_files.select { |candidate| broker.grants.check_root(candidate, broker.grants.read_roots).allowed? }

            matches = [] of Value

            in_bounds.each do |file|
              # The wall clock is checked per file. Exceeding it raises
              # the fatal `Exhausted` signal, not the recoverable
              # `Legate::Timeout` that §4.1 lists for grep.
              broker.budget.check_wall_clock!

              next unless File.file?(file) # a glob can match a directory; nothing to grep there
              next if looks_binary?(file)

              lines = read_lines(file, broker)
              # `Dir.glob` returns `\` separators on Windows, and
              # Legate::Path splits on `/` only, so the path is
              # converted first.
              path_val = Legate::Path.from_string(interp, path_cls, ::Path.new(file).to_posix.to_s, label)

              lines.each_with_index do |line, idx|
                next unless matches_pattern?(pattern, line)

                if matches.size + 1 > limit
                  ncc.raise_error_class(
                    "Legate.grep matched over #{limit} lines — narrow the pattern/paths or raise limit:.", too_many,
                  )
                end

                before = context > 0 ? lines[[0, idx - context].max...idx] : [] of String
                after = context > 0 ? lines[(idx + 1)...[lines.size, idx + 1 + context].min] : [] of String
                matches << Legate::Match.build(interp, match_cls, path_val, (idx + 1).to_i64, line, before, after, label)
              end
            end

            Value.new(LabeledArray.new(matches, label), label)
          end
        end

        # The pattern: a String or a Regexp. Raises R018 if missing and
        # R019 for another type, the codes String's pattern methods use,
        # naming `Legate.grep`.
        private def self.pattern_arg(pattern_val : Value?, ncc : NativeCallContext) : String | ::Regex
          if pattern_val.nil? || pattern_val.null?
            ncc.raise_error("R018", {"method" => "Legate.grep"}, "ArgumentError")
          end
          return pattern_val.as_string if pattern_val.string?
          if (robj = pattern_val.as_robject?) && robj.is_a?(Adjutant::RegexpObject)
            return robj.regex
          end
          ncc.raise_error("R019", {"method" => "Legate.grep", "class_name" => Builtins.builtin_type_name(pattern_val)}, "TypeError")
        end

        private def self.matches_pattern?(pattern : String | ::Regex, line : String) : Bool
          pattern.is_a?(::Regex) ? pattern.matches?(line) : line.includes?(pattern)
        end

        # The glob patterns from `paths` (a String, a Legate::Path, or
        # an Array of either, each rendered with `to_s`), and the join
        # of their labels.
        private def self.patterns_and_label(paths_val : Value, ncc : NativeCallContext) : {Array(String), RiskFlowLabel?}
          elements = paths_val.array? ? paths_val.as_array.to_a : [paths_val]
          label = nil.as(RiskFlowLabel?)
          patterns = elements.map do |element|
            str_val = ncc.call_method(element, "to_s", [] of Value)
            label = RiskFlowLabel.join(label, str_val.label)
            str_val.as_string
          end
          {patterns, label}
        end

        private def self.context_of(ncc : NativeCallContext) : Int32
          given = Helpers.checked_int_kwarg(ncc, "Legate.grep", "context")
          given ? given.to_i32 : DEFAULT_CONTEXT
        end

        private def self.limit_of(ncc : NativeCallContext) : Int32
          given = Helpers.checked_int_kwarg(ncc, "Legate.grep", "limit")
          given ? given.to_i32 : DEFAULT_LIMIT
        end

        private def self.looks_binary?(path : String) : Bool
          File.open(path, "rb") do |file|
            buf = ::Bytes.new(BINARY_SNIFF_BYTES)
            n = file.read(buf)
            buf[0, n].includes?(0_u8)
          end
        end

        # The file's lines, read whole (`context:` needs random access)
        # and recorded against the read budget after reading. Invalid
        # UTF-8 is always scrubbed; grep has no `scrub:`.
        private def self.read_lines(path : String, broker : Broker) : Array(String)
          raw_bytes = File.open(path, "rb") do |file|
            slice = ::Bytes.new(file.size)
            file.read_fully(slice)
            slice
          end
          broker.budget.record_read(raw_bytes.size.to_i64)
          raw_str = String.new(raw_bytes)
          scrubbed = raw_str.valid_encoding? ? raw_str : raw_str.scrub
          lines = scrubbed.split('\n')
          # No empty last line for a file ending in a newline, as
          # `Legate.lines` gives.
          lines.pop if lines.last? == ""
          lines
        end
      end
    end
  end
end
