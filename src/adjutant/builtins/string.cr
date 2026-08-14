require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"
require "./regexp"

module Adjutant::Builtins
  # Builds the `String` RubyClass and registers its native methods.
  #
  # `+` and `==`/`<`/`<=`/`>`/`>=` are NOT registered here — they
  # already compile to dedicated VM opcodes (ValueOps.add, .equal?,
  # .compare in value_ops.cr all already have real String cases) the
  # same way Integer/Float's arithmetic does. `[]` (indexing) is also
  # already a real opcode (Op::GetIndex, see exec_get_index) — not
  # registered here either.
  #
  # `*` (string repetition, `"ab" * 3`) is NOT supported — ValueOps.op
  # has no String case, only Integer/Float. A real, separate gap from
  # anything this class controls; noted, not fixed here (this class
  # only wires up NATIVE METHODS, not opcodes).
  #
  # `length`/`size` were previously served by exec_builtin's generic,
  # receiver-agnostic fallback case (see vm.cr) — registering them
  # here as real native methods makes THIS class authoritative for
  # String specifically going forward, via find_native_method, which
  # dispatch checks before ever reaching that fallback. The fallback's
  # own `string?` branch inside `length`/`size` is now dead code for
  # strings, but stays live for Array/Hash until those land too.
  # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
  def self.bootstrap_string(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("String")

    define(cls, interp, "to_s") do |args|
      args.first
    end

    define(cls, interp, "to_i") do |args|
      recv = args.first
      Adjutant::Value.int(recv.as_string.to_i64? || 0_i64, recv.label)
    end

    define(cls, interp, "to_f") do |args|
      recv = args.first
      Adjutant::Value.float(recv.as_string.to_f64? || 0.0, recv.label)
    end

    define(cls, interp, "to_sym") do |args|
      recv = args.first
      Adjutant::Value.symbol(interp.symbols.intern(recv.as_string), recv.label)
    end

    define(cls, interp, "length") do |args|
      Adjutant::Value.int(args.first.as_string.size.to_i64)
    end

    define(cls, interp, "size") do |args|
      Adjutant::Value.int(args.first.as_string.size.to_i64)
    end

    # upcase/downcase/strip/reverse/chars/capitalize all pass the
    # receiver's own label through to their result — a scalar-to-
    # scalar (or, for chars, scalar-to-container) transform of a
    # SINGLE labeled String, no combination of multiple sources
    # involved, so this is a direct carry-forward, not a join. Fixed
    # here alongside the new methods below (found while adding them —
    # upcase/downcase/strip previously dropped the receiver's label
    # entirely, the same category of gap already fixed for
    # Array#push/#map earlier this session).
    define(cls, interp, "upcase") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.upcase, recv.label)
    end

    define(cls, interp, "downcase") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.downcase, recv.label)
    end

    define(cls, interp, "strip") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.strip, recv.label)
    end

    define(cls, interp, "empty?") do |args|
      Adjutant::Value.bool(args.first.as_string.empty?)
    end

    define(cls, interp, "include?") do |args|
      needle = args[1]?.try(&.as_string?)
      Adjutant::Value.bool(needle ? args.first.as_string.includes?(needle) : false)
    end

    define(cls, interp, "split") do |args|
      recv = args.first
      s = recv.as_string
      sep_val = args[1]?
      # A `limit` (3rd arg) was never threaded through at all before —
      # `"a,".split(/,/, 1)` silently ignored the `1` and did an
      # ordinary unlimited split. Real Ruby's limit semantics: > 0
      # caps the field count (the LAST field holds whatever's left
      # unsplit, trailing empties KEPT); omitted/0 is unlimited but
      # drops trailing empty fields; negative is unlimited and KEEPS
      # them. Threaded through to Crystal's own `String#split(sep,
      # limit)` overloads below — not independently verified against
      # a toolchain here that Crystal's limit semantics line up with
      # Ruby's this closely; flag if `ops test` says otherwise. Only
      # threaded through the Regexp/String-separator branches, not the
      # bare whitespace-split (`s.split` with no separator) case below
      # — limit-plus-whitespace-split is a rare enough combination
      # that guessing at an unverified Crystal API shape for it isn't
      # worth the risk; a real, narrower gap if it ever comes up.
      limit = args[2]?.try(&.as_int?).try(&.to_i)
      parts =
        if (robj = sep_val.try(&.as_robject?)) && robj.is_a?(Adjutant::RegexpObject)
          limit ? s.split(robj.regex, limit) : s.split(robj.regex)
        elsif sep = sep_val.try(&.as_string?)
          limit ? s.split(sep, limit) : s.split(sep)
        else
          s.split
        end
      # Parts are substrings of a labeled receiver — the array as a
      # whole inherits the receiver's label, same principle as any other
      # construction from a labeled source (see MakeArray/MakeHash).
      Adjutant::Value.new(Adjutant::LabeledArray.new(parts.map { |part| Adjutant::Value.string(part) }, recv.label), nil)
    end

    define(cls, interp, "reverse") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.reverse, recv.label)
    end

    define(cls, interp, "chars") do |args|
      recv = args.first
      # Same label-inheritance principle as #split above — an Array
      # of single-character substrings of a labeled receiver.
      Adjutant::Value.new(Adjutant::LabeledArray.new(recv.as_string.chars.map { |char| Adjutant::Value.string(char.to_s) }, recv.label), nil)
    end

    define(cls, interp, "start_with?") do |args|
      prefix = args[1]?.try(&.as_string?)
      Adjutant::Value.bool(prefix ? args.first.as_string.starts_with?(prefix) : false)
    end

    define(cls, interp, "end_with?") do |args|
      suffix = args[1]?.try(&.as_string?)
      Adjutant::Value.bool(suffix ? args.first.as_string.ends_with?(suffix) : false)
    end

    # Real Ruby's String#capitalize upcases the first character and
    # downcases every other one (`"heLLO wOrld".capitalize ==
    # "Hello world"`) — NOT just an upcase of the first letter with
    # the rest left alone, which is a common mistake this
    # implementation deliberately avoids. Crystal's own
    # String#capitalize does exactly this already, no manual
    # first-char-splitting needed.
    define(cls, interp, "capitalize") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.capitalize, recv.label)
    end

    # Real Ruby's String#chomp(separator = "\n"): with no argument,
    # strips a single trailing "\r\n", else a single trailing "\n" or
    # "\r" (whichever is present) — NOT both a "\r" AND "\n"
    # separately. With an explicit non-empty separator, strips that
    # exact trailing substring if present, no newline-specific logic
    # at all. With an explicit EMPTY separator (`chomp("")`), strips
    # ALL trailing newlines (repeated "\r\n"/"\n" runs), Ruby's
    # "paragraph mode" chomp.
    define(cls, interp, "chomp") do |args|
      recv = args.first
      s = recv.as_string
      sep = args[1]?.try(&.as_string?)
      result = if sep.nil?
                 if s.ends_with?("\r\n")
                   s[0...-2]
                 elsif s.ends_with?("\n") || s.ends_with?("\r")
                   s[0...-1]
                 else
                   s
                 end
               elsif sep.empty?
                 t = s
                 loop do
                   if t.ends_with?("\r\n")
                     t = t[0...-2]
                   elsif t.ends_with?("\n")
                     t = t[0...-1]
                   else
                     break
                   end
                 end
                 t
               elsif s.ends_with?(sep)
                 s[0...(s.size - sep.size)]
               else
                 s
               end
      Adjutant::Value.string(result, recv.label)
    end

    # Real Ruby's String#each_line(separator = $/, &block): splits on
    # `separator`, keeping it attached to the END of each yielded
    # chunk (unlike #split, which discards the separator) — the
    # string reassembles exactly by concatenating every yielded
    # chunk. No trailing empty chunk is yielded when the string ends
    # exactly on a separator. Blockless call returns the receiver
    # unchanged (Enumerator-less, same convention as every other
    # Enumerable-less method here — see Array#each).
    #
    # KNOWN LIMITATION: real Ruby's "paragraph mode" (`each_line("")`
    # splits on runs of blank lines, collapsing consecutive
    # newlines) isn't implemented — an empty separator here just
    # falls back to the ordinary "\n" behavior instead of raising or
    # silently doing something else undocumented.
    define(cls, interp, "each_line") do |args, blk, ncc|
      recv = args.first
      s = recv.as_string
      sep = args[1]?.try(&.as_string?) || "\n"
      sep = "\n" if sep.empty?
      if blk
        pos = 0
        loop do
          idx = s.index(sep, pos)
          if idx
            chunk = s[pos..(idx + sep.size - 1)]
            ncc.invoke(blk, [Adjutant::Value.string(chunk, recv.label)])
            pos = idx + sep.size
          else
            chunk = s[pos..]
            ncc.invoke(blk, [Adjutant::Value.string(chunk, recv.label)]) unless chunk.empty?
            break
          end
        end
      end
      recv
    end

    # Real Ruby's String#index(pattern, start = 0): first occurrence
    # of `pattern` at or after `start` (negative `start` counts from
    # the end, same convention as `[]`'s own single-Integer indexing
    # elsewhere in this codebase — an out-of-range negative start
    # returns nil rather than clamping to 0). `pattern` is REQUIRED
    # (ArgumentError/R018 if omitted) and must be a String or a Regexp
    # (TypeError/R019 otherwise).
    define(cls, interp, "index") do |args, _blk, ncc|
      recv = args.first
      pattern = string_pattern_arg(args, "index", ncc)
      s = recv.as_string
      start = args[2]?.try(&.as_int.to_i) || 0
      start += s.size if start < 0
      next Adjutant::Value.nil_value if start < 0 || start > s.size
      idx = string_index_pattern(s, pattern, start)
      idx ? Adjutant::Value.int(idx.to_i64) : Adjutant::Value.nil_value
    end

    # Real Ruby's String#rindex(pattern, start = <end of string>):
    # LAST occurrence whose start position is at or before `start` —
    # searches backward, not forward. Negative `start` counts from
    # the end, same as #index; out of range (still negative after
    # adjustment) returns nil.
    define(cls, interp, "rindex") do |args, _blk, ncc|
      recv = args.first
      pattern = string_pattern_arg(args, "rindex", ncc)
      s = recv.as_string
      start = args[2]?.try(&.as_int.to_i) || s.size
      start += s.size if start < 0
      next Adjutant::Value.nil_value if start < 0
      start = s.size if start > s.size
      idx = string_rindex_pattern(s, pattern, start)
      idx ? Adjutant::Value.int(idx.to_i64) : Adjutant::Value.nil_value
    end

    # Real Ruby's String#sub/#gsub(pattern, replacement = nil, &block):
    # replace the first (#sub) or every non-overlapping (#gsub)
    # occurrence of `pattern`. Either a `replacement` String OR a
    # block is required — with a block, each match is yielded (as a
    # plain matched substring) and the block's return value (via
    # `#to_s`) is substituted in; with a replacement String, real
    # Ruby's backslash-reference syntax is honored (`\0`/`\&` the
    # match itself, `` \` ``/`\'` the pre-/post-match, `\\` a literal
    # backslash, `\1`-`\9` a Regexp pattern's capture groups — empty
    # for a literal String pattern, which has none). See
    # `string_sub_or_gsub`'s own comment for the zero-width
    # (empty-pattern) matching behavior this shares with both.
    define(cls, interp, "sub") do |args, blk, ncc|
      recv = args.first
      Adjutant::Value.string(string_sub_or_gsub(recv.as_string, args, blk, ncc, "sub", all: false), recv.label)
    end

    define(cls, interp, "gsub") do |args, blk, ncc|
      recv = args.first
      Adjutant::Value.string(string_sub_or_gsub(recv.as_string, args, blk, ncc, "gsub", all: true), recv.label)
    end

    # Real Ruby's String#match(pattern): unlike #index/#rindex/#sub/
    # #gsub/#split, a STRING pattern argument here is compiled as a
    # REGEX PATTERN, not searched for as a literal substring — real
    # Ruby's own `"hello".match("l+")` matches "ll" via regex
    # semantics, proving the point. That's genuinely different from
    # `string_pattern_arg`'s own String-case contract (a literal
    # substring, for #index's/#sub's callers), so this doesn't reuse
    # it — a real semantic difference, not an oversight.
    define(cls, interp, "match") do |args, _blk, ncc|
      recv = args.first
      pattern_val = args[1]?
      ncc.raise_error("R018", {"method" => "match"}, "ArgumentError") unless pattern_val
      regex, regexp_value =
        if (robj = pattern_val.as_robject?) && robj.is_a?(Adjutant::RegexpObject)
          {robj.regex, pattern_val}
        elsif pat_str = pattern_val.as_string?
          compiled = compile_regex(pat_str, 0, ncc)
          regexp_cls = interp.find_builtin_class("Regexp")
          raise "Regexp class not registered — bootstrap_regexp must run before any script executes" unless regexp_cls
          obj = Adjutant::RegexpObject.new(regexp_cls, compiled)
          obj.ivars[interp.symbols.intern("__source").value] = Adjutant::Value.string(pat_str)
          obj.ivars[interp.symbols.intern("__options").value] = Adjutant::Value.int(0)
          {compiled, Adjutant::Value.robject(obj)}
        else
          ncc.raise_error("R019", {"method" => "match", "class_name" => builtin_type_name(pattern_val)}, "TypeError")
        end
      if md = regex.match(recv.as_string)
        make_match_data(interp, md, recv.as_string, regexp_value)
      else
        Adjutant::Value.nil_value
      end
    end

    cls
  end

  # Shared by #index/#rindex/#sub/#gsub/#split — all require a pattern
  # argument (R018 if missing) that's either a String or a Regexp
  # (R019 for anything else). Returns the union rather than coercing
  # to one shape, since each caller needs different capabilities from
  # it (a literal String for #index's substring search vs. a real
  # ::Regex for capture groups in #sub/#gsub's backslash-refs) — see
  # `string_match_positions`/`string_index_pattern`/
  # `string_rindex_pattern` below, which all branch on this union
  # themselves rather than this method picking one representation
  # upfront.
  private def self.string_pattern_arg(args : Array(Adjutant::Value), method : String,
                                      ncc : Adjutant::NativeCallContext) : String | ::Regex
    pattern_val = args[1]?
    unless pattern_val
      ncc.raise_error("R018", {"method" => method}, "ArgumentError")
    end
    if pattern = pattern_val.as_string?
      return pattern
    end
    if (robj = pattern_val.as_robject?) && robj.is_a?(Adjutant::RegexpObject)
      return robj.regex
    end
    ncc.raise_error("R019", {"method" => method, "class_name" => builtin_type_name(pattern_val)}, "TypeError")
  end

  # #index's forward search, for either pattern kind. The Regex branch
  # uses Crystal's own `Regex#match(str, pos)` offset parameter (not
  # independently verified against a toolchain here — flag if `ops
  # test` reports otherwise) to search starting at `start`, exactly
  # matching `String#index(str, offset)`'s own contract for the
  # literal-String branch.
  private def self.string_index_pattern(s : String, pattern : String | ::Regex, start : Int32) : Int32?
    if pattern.is_a?(::Regex)
      md = pattern.match(s, start)
      md ? md.begin(0) : nil
    else
      s.index(pattern, start)
    end
  end

  # #rindex's backward search. Crystal's `String#rindex` has no Regex
  # overload the way `#index` does, so the Regex branch instead reuses
  # `string_match_positions`' own forward-scanning-with-captures loop
  # (finding every match is no more expensive than finding the last
  # one, and keeps the zero-width-match advance-by-1 logic in exactly
  # one place rather than a second copy here) and picks the last match
  # starting at or before `bound`.
  private def self.string_rindex_pattern(s : String, pattern : String | ::Regex, bound : Int32) : Int32?
    if pattern.is_a?(::Regex)
      string_match_positions(s, pattern, true)
        .reverse_each.find { |(start, _len, _captures)| start <= bound }
        .try { |(start, _len, _captures)| start }
    else
      s.rindex(pattern, bound)
    end
  end

  # Every non-overlapping match of literal String `pattern` in `s`,
  # as (start, length, captures) triples — shared by #sub/#gsub.
  # `all: false` stops after the first match (sub), `all: true` finds
  # every one (gsub). `captures` is `\1`-`\9`'s source for
  # `expand_backslash_refs` below — always empty for a literal String
  # pattern (which has no groups), populated from a real ::Regex
  # match's numbered capture groups otherwise.
  #
  # The empty-STRING-pattern case needs special handling: Ruby's
  # `"hello".gsub("", ".")` matches once at EVERY position from 0 to
  # s.size inclusive (6 matches for a 5-character string — before
  # each character, plus once after the last) — a naive
  # find-then-advance-past-the-match loop would either infinite-loop
  # (a zero-length match never advances `pos`) or skip valid
  # positions if advanced by the match length (always 0). Handled as
  # its own branch rather than trying to force the general loop below
  # to cover it. A Regexp pattern that can match zero-width (`//`,
  # `/x*/`) hits the same problem from the OTHER branch below, and is
  # handled the same way there — advance by 1, not by the match
  # length, whenever the match was zero-width.
  private def self.string_match_positions(s : String, pattern : String | ::Regex,
                                          all : Bool) : Array({Int32, Int32, Array(String?)})
    positions = [] of {Int32, Int32, Array(String?)}
    no_captures = [] of String?
    if pattern.is_a?(::Regex)
      pos = 0
      while pos <= s.size
        md = pattern.match(s, pos)
        break unless md
        start = md.begin(0) || pos
        matched = md[0]
        captures = (1..9).map { |i| md[i]? }
        positions << {start, matched.size, captures}
        pos = matched.empty? ? start + 1 : start + matched.size
        break unless all
      end
      return positions
    end
    if pattern.empty?
      (0..s.size).each do |i|
        positions << {i, 0, no_captures}
        break unless all
      end
      return positions
    end
    pos = 0
    while pos <= s.size
      idx = s.index(pattern, pos)
      break unless idx
      positions << {idx, pattern.size, no_captures}
      pos = idx + pattern.size
      break unless all
    end
    positions
  end

  # Expands real Ruby's backslash-reference syntax in a #sub/#gsub
  # replacement STRING (not a block return value, which is used
  # as-is) — `\\` a literal backslash, `\0`/`\&` the matched text,
  # `` \` `` everything before the match, `\'` everything after it,
  # `\1`-`\9` a capture group from `captures` (a literal String
  # pattern's `string_match_positions` call always supplies an empty
  # `captures`, so those stay empty here too — not a special case in
  # THIS method, just a consequence of never being asked for one).
  private def self.expand_backslash_refs(replacement : String, matched : String, pre_match : String,
                                         post_match : String, captures : Array(String?)) : String
    String.build do |io|
      i = 0
      while i < replacement.size
        ch = replacement[i]
        if ch == '\\' && i + 1 < replacement.size
          case replacement[i + 1]
          when '\\'     then io << '\\'
          when '0', '&' then io << matched
          when '`'      then io << pre_match
          when '\''     then io << post_match
          when '1'..'9' then io << (captures[replacement[i + 1].to_i - 1]? || "")
          else               io << ch << replacement[i + 1]
          end
          i += 2
        else
          io << ch
          i += 1
        end
      end
    end
  end

  # Shared body for #sub (all: false) / #gsub (all: true) — validates
  # the pattern (R018/R019, same as #index/#rindex), requires EITHER
  # a replacement String or a block (R018 if neither), then replaces
  # each matched position found by `string_match_positions` with
  # either the block's return value or the backslash-expanded
  # replacement string.
  private def self.string_sub_or_gsub(s : String, args : Array(Adjutant::Value), blk : Adjutant::ScriptProc?,
                                      ncc : Adjutant::NativeCallContext, method : String, all : Bool) : String
    pattern = string_pattern_arg(args, method, ncc)
    replacement_val = args[2]?
    # Real Ruby: a replacement STRING argument wins over a block when
    # BOTH are given — `"abc".sub(/b/, "X") { "Y" }` is "aXc", not
    # "aYc" (see the upstream mruby-regexp gem's own "replacement
    # string takes precedence over the block" test, which is exactly
    # what caught this). `replacement` is computed unconditionally
    # here (not `unless blk` as before — that was the actual bug: it
    # meant a given replacement string was silently ignored whenever a
    # block was ALSO present, always deferring to the block instead of
    # only when no replacement was given). `use_block` below is the
    # single place that decision gets made.
    replacement = replacement_val.try(&.as_string?)
    if replacement_val && replacement.nil? && blk.nil?
      # A replacement arg was given but isn't a String, and there's no
      # block to fall back on — same R019 a missing-block call would
      # eventually hit anyway, raised here instead so the message
      # names the real culprit (the wrong-type argument) rather than
      # a confusing "no replacement given" further down.
      ncc.raise_error("R019", {"method" => method, "class_name" => builtin_type_name(replacement_val)}, "TypeError")
    end
    if replacement.nil? && blk.nil?
      ncc.raise_error("R018", {"method" => method}, "ArgumentError")
    end

    # A single `resolver` proc, decided once, replaces the earlier
    # `use_block ? ... : ...` branch that ran INSIDE the match loop —
    # that version needed `blk.not_nil!`/`replacement.not_nil!` on
    # every iteration, since Crystal can't carry a plain `if blk`
    # narrowing of an outer local into a nested closure (the
    # `positions.each do |...|` block below recaptures `blk`/
    # `replacement` at their full nilable declared type, not
    # whatever was narrowed at the `if` check). Binding fresh,
    # already-non-nil locals (`b`, `r`) at proc-construction time,
    # OUTSIDE the loop, sidesteps that entirely — no `not_nil!`
    # anywhere, and the match loop itself stays a single shared body
    # instead of being duplicated per branch.
    resolver =
      if blk && replacement.nil?
        b = blk
        ->(matched : String, _pre : String, _post : String, _caps : Array(String?)) {
          ncc.invoke(b, [Adjutant::Value.string(matched)]).to_s
        }
      elsif r = replacement
        ->(matched : String, pre : String, post : String, caps : Array(String?)) {
          expand_backslash_refs(r, matched, pre, post, caps)
        }
      else
        raise "unreachable: validated above that a replacement or a block is present"
      end

    positions = string_match_positions(s, pattern, all)
    String.build do |io|
      last_end = 0
      positions.each do |(start, len, captures)|
        io << s[last_end...start]
        matched = s[start, len]
        io << resolver.call(matched, s[0...start], s[(start + len)..], captures)
        last_end = start + len
      end
      io << s[last_end..]
    end
  end
end
