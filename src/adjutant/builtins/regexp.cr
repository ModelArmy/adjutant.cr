require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

# A Regexp's state: the compiled `::Regex`, which has no Value
# variant so can't be an ivar, alongside the `__source` and
# `__options` ivars that `source` and `options` return.
module Adjutant
  class RegexpObject < RubyObject
    getter regex : ::Regex

    def initialize(rclass : RubyClass, @regex : ::Regex)
      super(rclass)
    end
  end

  # A MatchData's state: Crystal's `::Regex::MatchData` and the
  # subject string it matched.
  class MatchDataObject < RubyObject
    getter md : ::Regex::MatchData
    getter subject : String
    getter regexp_value : Value

    def initialize(rclass : RubyClass, @md : ::Regex::MatchData, @subject : String, @regexp_value : Value)
      super(rclass)
    end
  end

  module Builtins
    # Ruby's values for Regexp::IGNORECASE, EXTENDED and MULTILINE.
    IGNORECASE = 1
    EXTENDED   = 2
    MULTILINE  = 4

    # Converts Adjutant's flag bitmask to `::Regex::Options`. In
    # Ruby, `^` and `$` always match at line boundaries, which PCRE2
    # does only under its MULTILINE option, so that is always passed.
    # Ruby's `m` flag (dot matches newline) maps to DOTALL.
    def self.regex_options(adjutant_flags : Int32) : ::Regex::Options
      opts = ::Regex::Options::MULTILINE # real Ruby's ^/$ semantics, always on
      opts |= ::Regex::Options::IGNORE_CASE if adjutant_flags & IGNORECASE != 0
      opts |= ::Regex::Options::DOTALL if adjutant_flags & MULTILINE != 0
      opts |= ::Regex::Options::EXTENDED if adjutant_flags & EXTENDED != 0
      opts
    end

    # The enabled and disabled flag letters, each in `m`, `i`, `x`
    # order, as `to_s` and `inspect` write them.
    def self.flag_letters(adjutant_flags : Int32) : {String, String}
      enabled = String.build do |io|
        io << 'm' if adjutant_flags & MULTILINE != 0
        io << 'i' if adjutant_flags & IGNORECASE != 0
        io << 'x' if adjutant_flags & EXTENDED != 0
      end
      disabled = String.build do |io|
        io << 'm' if adjutant_flags & MULTILINE == 0
        io << 'i' if adjutant_flags & IGNORECASE == 0
        io << 'x' if adjutant_flags & EXTENDED == 0
      end
      {enabled, disabled}
    end

    # Escapes each `/` in `pattern` not already preceded by `\`. A
    # `/` after an escaped backslash (`a\\/b`) is left unescaped.
    def self.escape_slashes(pattern : String) : String
      String.build do |io|
        prev_backslash = false
        pattern.each_char do |char|
          io << '\\' if char == '/' && !prev_backslash
          io << char
          prev_backslash = char == '\\'
        end
      end
    end

    # Compiles `pattern`, raising R021 (RegexpError) for an invalid
    # one. `ctx` is nil for a regex literal, which the VM compiles
    # without a NativeCallContext; the error is then raised by the
    # caller.
    def self.compile_regex(pattern : String, adjutant_flags : Int32,
                           ctx : NativeCallContext?) : ::Regex
      ::Regex.new(pattern, regex_options(adjutant_flags))
    rescue ex : ::Exception
      reason = ex.message || "invalid pattern"
      if ctx
        ctx.raise_error("R021", {"reason" => reason}, error_class: "RegexpError")
      else
        raise ex
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each an independent registration; the count comes from how many methods Regexp has, not from tangled branching
    def self.bootstrap_regexp(interp : Interpreter) : RubyClass
      cls = RubyClass.new("Regexp")
      cls.constants[interp.symbols.intern("IGNORECASE").value] = Value.int(IGNORECASE)
      cls.constants[interp.symbols.intern("EXTENDED").value] = Value.int(EXTENDED)
      cls.constants[interp.symbols.intern("MULTILINE").value] = Value.int(MULTILINE)

      source_sym = interp.symbols.intern("__source").value
      options_sym = interp.symbols.intern("__options").value

      # `Regexp.new(pattern, options = 0)`, or `Regexp.new(regexp)` to
      # copy one. Allocates the receiver's class, so a subclass gets
      # instances of itself.
      define_singleton(cls, interp, "new") do |args, _blk, ncc|
        first = args[1]? || Value.nil_value
        pattern, flags =
          if (robj = first.as_robject?) && robj.is_a?(RegexpObject)
            {robj.ivars[source_sym].as_string, robj.ivars[options_sym].as_int.to_i32}
          else
            {first.as_string, (args[2]?.try(&.as_int.to_i32) || 0)}
          end
        regex = compile_regex(pattern, flags, ncc)
        obj = RegexpObject.new(args.first.as_rclass, regex)
        # The pattern's label carries to the object and to `source`;
        # the options bitmask is metadata, so unlabelled.
        obj.ivars[source_sym] = Value.string(pattern, first.label)
        obj.ivars[options_sym] = Value.int(flags)
        Value.robject(obj, first.label)
      end

      define(cls, interp, "source") do |args|
        args.first.as_robject.ivars[source_sym]
      end

      define(cls, interp, "options") do |args|
        args.first.as_robject.ivars[options_sym]
      end

      define(cls, interp, "casefold?") do |args|
        flags = args.first.as_robject.ivars[options_sym].as_int.to_i32
        Value.bool(flags & IGNORECASE != 0)
      end

      # `to_s` is `(?enabled-disabled:pattern)`, as `/a/i.to_s` is
      # "(?i-mx:a)", with `-disabled` omitted when every flag is set.
      # `inspect` is `/pattern/flags`, escaping `/`:
      # `Regexp.new("a/b").inspect` is `/a\/b/`.
      define(cls, interp, "to_s") do |args|
        obj = args.first.as_robject
        pattern = obj.ivars[source_sym].as_string
        flags = obj.ivars[options_sym].as_int.to_i32
        enabled, disabled = flag_letters(flags)
        suffix = disabled.empty? ? "" : "-#{disabled}"
        Value.string("(?#{enabled}#{suffix}:#{pattern})")
      end

      define(cls, interp, "inspect") do |args|
        obj = args.first.as_robject
        pattern = escape_slashes(obj.ivars[source_sym].as_string)
        flags = obj.ivars[options_sym].as_int.to_i32
        enabled, _ = flag_letters(flags)
        Value.string("/#{pattern}/#{enabled}")
      end

      # A MatchData, or nil on no match. The argument must be a String;
      # anything else, including nil, raises R022. With a block, the
      # MatchData is yielded on a match and the block's result
      # returned.
      define(cls, interp, "match") do |args, blk, ncc|
        robj = args.first.as_robject.as(RegexpObject)
        str = args[1]?.try(&.as_string?)
        ncc.raise_error("R022", {"method" => "match"}, "ArgumentError") unless str
        if md = robj.regex.match(str)
          # The MatchData's label joins the subject's and the
          # Regexp's.
          match_label = RiskFlowLabel.join(args[1]?.try(&.label), args.first.label)
          match_data = make_match_data(interp, md, str, args.first, match_label)
          blk ? ncc.invoke(blk, [match_data]) : match_data
        else
          Value.nil_value
        end
      end

      # Whether it matches, without building a MatchData.
      define(cls, interp, "match?") do |args, _blk, ncc|
        robj = args.first.as_robject.as(RegexpObject)
        str = args[1]?.try(&.as_string?)
        ncc.raise_error("R022", {"method" => "match?"}, "ArgumentError") unless str
        Value.bool(robj.regex.matches?(str))
      end

      # The index of the first match, or nil. The argument must be a
      # String (R022). Sets no `$~` or `$1` (U011).
      define(cls, interp, "=~") do |args, _blk, ncc|
        robj = args.first.as_robject.as(RegexpObject)
        str = args[1]?.try(&.as_string?)
        ncc.raise_error("R022", {"method" => "=~"}, "ArgumentError") unless str
        if md = robj.regex.match(str)
          pos = md.begin(0)
          pos ? Value.int(pos.to_i64) : Value.nil_value
        else
          Value.nil_value
        end
      end

      # `===` is the TripleEq opcode, not a method, so
      # `/re/.===(s)` is an undefined method.
      cls
    end

    # Builds a MatchData object from a Crystal match. `label` is the
    # join of the subject's and the Regexp's labels, computed by the
    # caller.
    def self.make_match_data(interp : Interpreter, md : ::Regex::MatchData, subject : String,
                             regexp_value : Value, label : RiskFlowLabel?) : Value
      cls = interp.find_builtin_class("MatchData")
      raise "MatchData class not registered — bootstrap_match_data must run before any script executes" unless cls
      Value.robject(MatchDataObject.new(cls, md, subject, regexp_value), label)
    end

    # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
    def self.bootstrap_match_data(interp : Interpreter) : RubyClass
      cls = RubyClass.new("MatchData")

      # Accessors returning part of the subject (`[]`, `to_s`,
      # `pre_match`, `post_match`, `string`, `captures`) carry the
      # MatchData's label; the positions `begin` and `end` don't.
      #
      # `[]`: an Integer (0 the whole match) or a group name. Nil for
      # an index out of range, a group that didn't participate, or an
      # unknown name, where Ruby raises IndexError.
      define(cls, interp, "[]") do |args, _blk, _ncc|
        obj = args.first.as_robject.as(MatchDataObject)
        key = args[1]?
        next Value.nil_value unless key
        result =
          if i = key.as_int?
            obj.md[i.to_i]?
          else
            name = key.as_string? || key.as_sym?.try(&.name)
            name ? obj.md[name]? : nil
          end
        result ? Value.string(result, args.first.label) : Value.nil_value
      end

      define(cls, interp, "to_s") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.md[0], args.first.label)
      end

      define(cls, interp, "pre_match") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.md.pre_match, args.first.label)
      end

      define(cls, interp, "post_match") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.md.post_match, args.first.label)
      end

      define(cls, interp, "string") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.subject, args.first.label)
      end

      define(cls, interp, "begin") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        n = args[1]?.try(&.as_int.to_i) || 0
        pos = obj.md.begin(n)
        pos ? Value.int(pos.to_i64) : Value.nil_value
      end

      # The offset just past a group's match.
      define(cls, interp, "end") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        n = args[1]?.try(&.as_int.to_i) || 0
        pos = obj.md.end(n)
        pos ? Value.int(pos.to_i64) : Value.nil_value
      end

      # Every numbered group's text, without the whole match; nil for
      # a group that didn't participate.
      define(cls, interp, "captures") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        caps = (1...obj.md.size).map { |i| (c = obj.md[i]?) ? Value.string(c, args.first.label) : Value.nil_value }
        Value.new(LabeledArray.new(caps, args.first.label), nil)
      end

      # The Regexp that produced the match.
      define(cls, interp, "regexp") do |args|
        args.first.as_robject.as(MatchDataObject).regexp_value
      end

      # `#<MatchData "abc" 1:"b" mid:"c">`: the whole match, then each
      # group by name if it has one, else by number, `nil` unquoted
      # for a group that didn't participate. Each text is its String
      # `inspect`.
      define(cls, interp, "inspect") do |args, _blk, ncc|
        obj = args.first.as_robject.as(MatchDataObject)
        regexp_obj = obj.regexp_value.as_robject.as(RegexpObject)
        names = regexp_obj.regex.name_table
        whole = ncc.call_method(Value.string(obj.md[0]), "inspect", [] of Value).as_string
        groups = (1...obj.md.size).map do |i|
          text = obj.md[i]?
          rendered = text ? ncc.call_method(Value.string(text), "inspect", [] of Value).as_string : "nil"
          label = names[i]? || i.to_s
          "#{label}:#{rendered}"
        end
        parts = [whole] + groups
        Value.string("#<MatchData #{parts.join(" ")}>")
      end

      cls
    end
  end
end
