require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"
require "./regexp"

module Adjutant::Builtins
  # Builds the `String` class and its native methods. `+`, the
  # comparisons and `[]` are opcodes, not methods. `*` isn't
  # supported.
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

    # A one-string transform carries the receiver's label to its
    # result.
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
      # A `limit` applies to Regexp and String separators, through
      # Crystal's `split(sep, limit)`; it is ignored for a whitespace
      # split.
      limit = args[2]?.try(&.as_int?).try(&.to_i)
      parts =
        if (robj = sep_val.try(&.as_robject?)) && robj.is_a?(Adjutant::RegexpObject)
          limit ? s.split(robj.regex, limit) : s.split(robj.regex)
        elsif sep = sep_val.try(&.as_string?)
          limit ? s.split(sep, limit) : s.split(sep)
        else
          s.split
        end
      # Each piece's label, and the Array's, joins the receiver's and
      # the separator's.
      whole_label = Adjutant::RiskFlowLabel.join(recv.label, sep_val.try(&.label))
      Adjutant::Value.new(Adjutant::LabeledArray.new(parts.map { |part| Adjutant::Value.string(part, whole_label) }, whole_label), nil)
    end

    define(cls, interp, "reverse") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.reverse, recv.label)
    end

    define(cls, interp, "chars") do |args|
      recv = args.first
      # Each character carries the receiver's label.
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

    # Upcases the first character and downcases the rest, as in Ruby.
    define(cls, interp, "capitalize") do |args|
      recv = args.first
      Adjutant::Value.string(recv.as_string.capitalize, recv.label)
    end

    # With no argument, strips one trailing "\r\n", "\n" or "\r".
    # With a separator, strips it if the string ends with it; with
    # "", strips every trailing newline.
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

    # Yields each line with its separator attached, so the chunks
    # rejoin into the string; no empty chunk after a final separator.
    # Without a block, returns the receiver. An empty separator splits
    # on "\n", not by paragraph as Ruby does.
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

    # The first index of `pattern` (a String or Regexp) at or after
    # `start`; a negative `start` counts from the end, and one still
    # negative gives nil. A missing pattern raises R018
    # (`ArgumentError`), another type R019 (`TypeError`).
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

    # The last index of `pattern` starting at or before `start`,
    # default the end; negative `start` as for `index`.
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

    # Replaces the first (`sub`) or every (`gsub`) match of `pattern`
    # with `replacement`, which honours `\0`, `\&`, `` \` ``, `\'`,
    # `\\` and `\1` to `\9`, or with the block's result for each
    # match. The result's label joins the receiver's and the pattern's,
    # but not the replacement's or the block results'.
    define(cls, interp, "sub") do |args, blk, ncc|
      recv = args.first
      result_label = Adjutant::RiskFlowLabel.join(recv.label, args[1]?.try(&.label))
      Adjutant::Value.string(string_sub_or_gsub(recv.as_string, args, blk, ncc, "sub", all: false), result_label)
    end

    define(cls, interp, "gsub") do |args, blk, ncc|
      recv = args.first
      result_label = Adjutant::RiskFlowLabel.join(recv.label, args[1]?.try(&.label))
      Adjutant::Value.string(string_sub_or_gsub(recv.as_string, args, blk, ncc, "gsub", all: true), result_label)
    end

    # A String pattern is compiled as a regex, as in Ruby
    # (`"hello".match("l+")` matches "ll"), unlike `index`, `sub` and
    # `split`, where it is literal.
    define(cls, interp, "match") do |args, blk, ncc|
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
          # The synthesized Regexp's source carries the pattern's
          # label, as for `Regexp.new`.
          obj.ivars[interp.symbols.intern("__source").value] = Adjutant::Value.string(pat_str, pattern_val.label)
          obj.ivars[interp.symbols.intern("__options").value] = Adjutant::Value.int(0)
          {compiled, Adjutant::Value.robject(obj, pattern_val.label)}
        else
          ncc.raise_error("R019", {"method" => "match", "class_name" => builtin_type_name(pattern_val)}, "TypeError")
        end
      if md = regex.match(recv.as_string)
        # The MatchData's label joins the subject's and the
        # pattern's.
        match_label = Adjutant::RiskFlowLabel.join(recv.label, regexp_value.label)
        match_data = make_match_data(interp, md, recv.as_string, regexp_value, match_label)
        # With a block, the MatchData is yielded and the block's
        # result returned.
        blk ? ncc.invoke(blk, [match_data]) : match_data
      else
        Adjutant::Value.nil_value
      end
    end

    # The index of the first match of a Regexp, or nil. A String on
    # the right raises R033 (`TypeError`), as in Ruby; `match` is the
    # one that accepts a String.
    define(cls, interp, "=~") do |args, _blk, ncc|
      recv = args.first
      pattern_val = args[1]?
      regex =
        if pattern_val && (robj = pattern_val.as_robject?) && robj.is_a?(Adjutant::RegexpObject)
          robj.regex
        else
          ncc.raise_error("R033", {"method" => "=~", "class_name" => builtin_type_name(pattern_val || Adjutant::Value.nil_value)}, "TypeError")
        end
      if md = regex.match(recv.as_string)
        pos = md.begin(0)
        pos ? Adjutant::Value.int(pos.to_i64) : Adjutant::Value.nil_value
      else
        Adjutant::Value.nil_value
      end
    end

    cls
  end

  # The pattern argument of `index`, `rindex`, `sub`, `gsub` and
  # `split`: a String or a ::Regex, left as a union for the caller.
  # Raises R018 if missing, R019 for another type.
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

  # The first match of `pattern` at or after `start`.
  private def self.string_index_pattern(s : String, pattern : String | ::Regex, start : Int32) : Int32?
    if pattern.is_a?(::Regex)
      md = pattern.match(s, start)
      md ? md.begin(0) : nil
    else
      s.index(pattern, start)
    end
  end

  # The last match of `pattern` starting at or before `bound`. For a
  # Regex, which Crystal's `rindex` doesn't take, it scans every
  # match with `string_match_positions` and keeps the last.
  private def self.string_rindex_pattern(s : String, pattern : String | ::Regex, bound : Int32) : Int32?
    if pattern.is_a?(::Regex)
      string_match_positions(s, pattern, true)
        .reverse_each.find { |(start, _len, _captures)| start <= bound }
        .try { |(start, _len, _captures)| start }
    else
      s.rindex(pattern, bound)
    end
  end

  # Every non-overlapping match of `pattern` in `s` as (start,
  # length, captures), or only the first if `all` is false. Captures
  # are empty for a String pattern. A zero-width match advances one
  # position, so `"hello".gsub("", ".")` matches at all six positions,
  # as in Ruby.
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

  # Expands a `sub` or `gsub` replacement's backslash references:
  # `\\`, `\0` or `\&` (the match), `` \` `` (before it), `\'` (after
  # it), `\1` to `\9` (captures).
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

  # The shared body of `sub` and `gsub`: validates the pattern,
  # requires a replacement String or a block (R018), and replaces
  # each match.
  private def self.string_sub_or_gsub(s : String, args : Array(Adjutant::Value), blk : Adjutant::ScriptProc?,
                                      ncc : Adjutant::NativeCallContext, method : String, all : Bool) : String
    pattern = string_pattern_arg(args, method, ncc)
    replacement_val = args[2]?
    # A replacement String wins over a block when both are given, as
    # in Ruby: `"abc".sub(/b/, "X") { "Y" }` is "aXc".
    replacement = replacement_val.try(&.as_string?)
    if replacement_val && replacement.nil? && blk.nil?
      # A replacement that isn't a String, with no block: R019, naming
      # the argument.
      ncc.raise_error("R019", {"method" => method, "class_name" => builtin_type_name(replacement_val)}, "TypeError")
    end
    if replacement.nil? && blk.nil?
      ncc.raise_error("R018", {"method" => method}, "ArgumentError")
    end

    # Chosen once, outside the loop, with non-nil captures, since a
    # closure can't see an `if`'s narrowing of `blk`.
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
