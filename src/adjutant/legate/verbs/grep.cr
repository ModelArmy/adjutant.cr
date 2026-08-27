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
      # Array<Legate::Match>` — LEGATE.md §4.1. "This verb exists so
      # that scripts do not need the `exec` grant to run `rg`" (§4.1's
      # own words) — the whole point is doing content search WITHOUT
      # shelling out, so this is real Crystal-side line scanning, not
      # a wrapper around a `grep`/`rg` binary.
      #
      # `pattern` is a String (literal substring search) or a Regexp
      # (real regex search) — same `String | Regexp` union
      # `builtins/string.cr`'s own `#index`/`#sub`/`#gsub`/`#split`
      # already established for exactly this "either kind of pattern"
      # shape (`string_pattern_arg`, that file's own comment); this
      # verb's `pattern_arg` below is a small Legate-local echo of the
      # same idea, reusing R018/R019 (that file's own error codes)
      # directly rather than adding Legate-specific duplicates, since
      # the underlying situation — a required pattern argument that's
      # neither a String nor a Regexp — is identical.
      #
      # `paths` is a glob string OR an Array (LEGATE.md §4.1's own
      # words) — normalized here into a flat list of glob PATTERNS
      # either way (a bare String is just a one-element list), each
      # independently expanded via `Dir.glob`. This unifies the two
      # accepted shapes onto one code path rather than branching:
      # `Dir.glob` on a literal, wildcard-free path already does
      # exactly the right thing for an array element that's a plain
      # file path (returns `[path]` if it exists, `[]` if not), so an
      # Array mixing literal paths and glob patterns "just works"
      # without this verb needing to tell the two apart itself.
      module Grep
        KWARG_NAMES     = Set{"context", "limit"}
        DEFAULT_LIMIT   = 10_000
        DEFAULT_CONTEXT =      0

        # git's own "does this file look binary" heuristic (a NUL
        # byte within the first N bytes) — the specific byte count
        # (8000) matches git's own convention, chosen because it's a
        # widely-used, well-understood heuristic rather than an
        # invented one; LEGATE.md's own "binary files skipped" (§4.1)
        # doesn't specify a detection method.
        BINARY_SNIFF_BYTES = 8000

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          too_many = Helpers.fetch(legate, interp, "TooMany")
          match_cls = Helpers.fetch(legate, interp, "Match")
          path_cls = Helpers.fetch(legate, interp, "Path")

          legate.define_native_singleton_method(
            interp.symbols.intern("grep").value,
            RiskProfile.new(tags: Set{RiskTag::ReadsFiles}),
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            # Pattern/paths/context/limit ALL validated FIRST, before
            # any grant/authorization work — same "a bad call-site
            # argument is a programmer error, unrelated to the path or
            # the grant" reasoning `records.cr`'s own `format:`
            # validation ordering established. `context`/`limit`
            # weren't originally included in this — moved up here as
            # part of SCOPE.md's "kwarg-validation ordering
            # inconsistent across the read-verb slice" entry (added
            # 2026-08-27): the principle was already right for
            # `pattern`/`paths` in this same file, just not yet
            # extended to this file's OWN two kwargs.
            pattern = pattern_arg(args[1]?, ncc)
            context = context_of(ncc)
            limit = limit_of(ncc)

            paths_val = args[2]?
            if paths_val.nil?
              ncc.raise_error("R035", {} of String => String, "ArgumentError")
            end
            patterns, label = patterns_and_label(paths_val, ncc)
            posix_patterns = patterns.map { |raw_pattern| ::Path.new(raw_pattern).to_posix.to_s }

            # ONE `authorize_read` call per DISTINCT fixed-prefix
            # directory across every pattern — not one per pattern
            # (two patterns rooted in the SAME directory shouldn't
            # produce two audit records/policy consultations for that
            # one directory) and not one per matched FILE (`list.cr`'s
            # own "not one per matched file" reasoning applies here
            # even more, since grep's per-file work — reading and
            # scanning content — is far more expensive than list's
            # per-file `File.info?`). `.uniq!` is what makes this a
            # real dedup, not just "fewer calls than files."
            prefixes = posix_patterns.map { |posix_pattern| Helpers.fixed_prefix(posix_pattern) }.uniq!
            prefixes.each do |prefix|
              label = RiskFlowLabel.join(label, broker.authorize_read(prefix, ncc, allow_missing: true))
            end

            matched_files = posix_patterns.flat_map { |posix_pattern| Dir.glob(posix_pattern) }.uniq!.sort!
            # Defense in depth, not primary enforcement — same
            # reasoning and same NOT-a-second-audit-entry shape as
            # `list.cr`'s own identical line.
            in_bounds = matched_files.select { |candidate| broker.grants.check_root(candidate, broker.grants.read_roots).allowed? }

            matches = [] of Value

            in_bounds.each do |file|
              # Checked WALL-CLOCK per file, not just once for the
              # whole call — LEGATE.md §4.1 lists `Timeout` among
              # grep's own Raises, unlike every other §4.1 verb, which
              # only makes sense if grep is expected to notice it's
              # taking too long mid-scan across a large fileset, not
              # only at the single up-front broker call every other
              # verb does. JUDGMENT CALL, flagged rather than silently
              # assumed: `Budget#check_wall_clock!` raises the FATAL,
              # unrescuable `Legate::FatalSignal(:exhausted, ...)` —
              # NOT the script-catchable `Legate::Timeout` RuntimeError
              # class LEGATE.md's own §4.1 entry seems to name. No
              # kwarg or default duration for a SEPARATE, grep-local,
              # recoverable timeout is documented anywhere in
              # LEGATE.md, so inventing one (a second, independent
              # timer with its own semantics) felt like more new,
              # unspecified machinery than this session should decide
              # unilaterally — logged as a SCOPE.md item instead. This
              # at least gives grep the SAME real, working protection
              # against a runaway multi-file scan every other verb's
              # single broker call already gets, even if the raised
              # class doesn't literally match "Timeout."
              broker.budget.check_wall_clock!

              next unless File.file?(file) # a glob can match a directory; nothing to grep there
              next if looks_binary?(file)

              lines = read_lines(file, broker)
              # `::Path.new(...).to_posix` — `Legate::Path` splits
              # ONLY on `/` by deliberate design (path.cr's own
              # POSIX-style abstraction, independent of the host OS —
              # see that file's own comment), but `file` here came
              # straight out of `Dir.glob`, which returns SYSTEM-
              # SPECIFIC separators regardless of the pattern's own
              # (`\`-joined on Windows) — the exact same fact this
              # file's own `posix_patterns` normalization already
              # accounts for on the PATTERN side, just missed here on
              # the MATCHED-FILE side. Without this, `.basename` (and
              # `.dirname`/`.parts`) on a Windows-built `Match`'s
              # `path` silently finds no `/` to split on and returns
              # the WHOLE path unchanged — caught by a Windows CI
              # runner, not by inspection.
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

        # `R018`/`R019` — see this module's own top comment for why
        # these are REUSED from `builtins/string.cr` rather than given
        # Legate-specific codes: a required-but-missing, or present-
        # but-wrong-type, pattern argument is the same situation
        # either way. `method: "Legate.grep"` is what makes the
        # rendered message say the right call site despite the code
        # being shared.
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

        # Normalizes `paths` (a bare String/Path, or an Array of
        # either) into a flat `Array(String)` of glob patterns, plus
        # the JOIN of every element's own label — same "the path
        # argument's pre-existing taint survives" reasoning every
        # other verb's `str_val.label` already carries, just folded
        # across potentially several elements instead of one. Each
        # element goes through the SAME real `#to_s` dispatch every
        # other verb uses (`ncc.call_method(elem, "to_s", ...)`), so a
        # `Legate::Path` array element works identically to a String
        # one — neither this verb nor a script author needs to
        # convert one to the other first.
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

        # Whole-file read (not `Lines::LineIterator` — grep needs
        # RANDOM access across a file's lines for `context:`, not a
        # forward-only pull), raw bytes then decoded via
        # `valid_encoding?`/`#scrub` — the CORRECTED scrub approach
        # `lines.cr` settled on this session (`ops test` disproved the
        # original `String.new(Bytes)`-substitutes assumption
        # `read.cr` was still built on), not that still-unfixed one.
        # Always scrubs (no `scrub:` kwarg — LEGATE.md's own grep
        # signature doesn't have one): grep is a best-effort content
        # search, not a strict-encoding verb, and `Malformed` isn't
        # among grep's own documented Raises.
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
          # No trailing blank "line" for a file ending in `\n` —
          # matches `Lines::LineIterator`'s own chomp convention
          # (lines.cr), so a script sees the same line count/shape
          # whether it read a file via `Legate.lines` or found it via
          # `Legate.grep`.
          lines.pop if lines.last? == ""
          lines
        end
      end
    end
  end
end
