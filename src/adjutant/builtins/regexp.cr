require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

# A Regexp instance's real state: the compiled Crystal `::Regex` plus
# the two Ruby-visible attributes mirrored into ivars for
# `#source`/`#options`. The compiled `::Regex` itself can't live in
# `ivars` — there's no `Value` variant for it, the same reason
# `ScriptProc`'s closure snapshot lives in its own `outer_locals`
# field rather than in `ivars` (see `RubyObject`'s own doc comment) —
# so it gets a real typed field here instead, the exact subclassing
# pattern that comment describes for a builtin with real internal
# state.
module Adjutant
  class RegexpObject < RubyObject
    getter regex : ::Regex

    def initialize(rclass : RubyClass, @regex : ::Regex)
      super(rclass)
    end
  end

  # A MatchData instance's real state: Crystal's own
  # `::Regex::MatchData`, plus the subject string it matched against
  # kept alongside it explicitly (rather than trusting a `.string`-
  # style accessor to exist on `::Regex::MatchData` itself, which
  # isn't independently verified here — see the same "not verified"
  # caveat on Builtins.regex_options below). Same subclassing
  # rationale as RegexpObject above: no `Value` variant exists for
  # either Crystal type, so both get real typed fields here instead
  # of living in `ivars`.
  class MatchDataObject < RubyObject
    getter md : ::Regex::MatchData
    getter subject : String

    def initialize(rclass : RubyClass, @md : ::Regex::MatchData, @subject : String)
      super(rclass)
    end
  end

  module Builtins
    # Bit values for Regexp::IGNORECASE/MULTILINE/EXTENDED. These match
    # real Ruby's own values as best recalled — NOT independently
    # verified against a live Ruby here (no toolchain in this
    # environment). The mruby fixture only ever compares these
    # symbolically (`Regexp::IGNORECASE | Regexp::MULTILINE`, never a
    # bare literal), so an internal mismatch with real Ruby's numbers
    # wouldn't fail anything in-repo — but flag it if something external
    # ever depends on the literal value.
    IGNORECASE = 1
    EXTENDED   = 2
    MULTILINE  = 4

    # Compiles Adjutant's Ruby-facing flag bitmask into Crystal's own
    # Regex::Options. The one genuinely load-bearing piece here: real
    # Ruby's `^`/`$` ALWAYS match line boundaries — that's not gated by
    # any flag — while PCRE2/Crystal only do that under
    # Regex::Options::MULTILINE. So MULTILINE is passed
    # UNCONDITIONALLY below, regardless of whether the script's own
    # Regexp::MULTILINE bit was set. Ruby's `/m` flag means something
    # different (dot matches newline, PCRE2's DOTALL) and is mapped to
    # DOTALL separately. Getting this backwards would be exactly the
    # "ran, looked plausible, was wrong" bug class this project stays
    # alert for — see the compatibility discussion in the handoff this
    # phase came out of.
    #
    # Crystal's exact Regex::Options member names below (IGNORE_CASE /
    # MULTILINE / DOTALL / EXTENDED) are not independently verified
    # against a toolchain here — no local `crystal` binary to check
    # against. If `ops test` reports an unknown constant, this is the
    # first place to look.
    def self.regex_options(adjutant_flags : Int32) : ::Regex::Options
      opts = ::Regex::Options::MULTILINE # real Ruby's ^/$ semantics, always on
      opts |= ::Regex::Options::IGNORE_CASE if adjutant_flags & IGNORECASE != 0
      opts |= ::Regex::Options::DOTALL if adjutant_flags & MULTILINE != 0
      opts |= ::Regex::Options::EXTENDED if adjutant_flags & EXTENDED != 0
      opts
    end

    # Compiles `pattern` under `adjutant_flags`, raising a real,
    # script-catchable R021 (RegexpError) through `ctx` on an invalid
    # pattern rather than letting Crystal's own Regex::Error escape and
    # get flattened into an opaque internal N001 (see
    # NativeCallContext#raise_error's own doc comment for why that
    # matters). `ctx` is nilable because Op::MakeRegex (a literal,
    # evaluated directly by the VM with no NativeCallContext in scope)
    # needs the same compile step as `Regexp.new` — see
    # VM#make_regexp_object.
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

    def self.bootstrap_regexp(interp : Interpreter) : RubyClass
      cls = RubyClass.new("Regexp")
      cls.constants[interp.symbols.intern("IGNORECASE").value] = Value.int(IGNORECASE)
      cls.constants[interp.symbols.intern("EXTENDED").value] = Value.int(EXTENDED)
      cls.constants[interp.symbols.intern("MULTILINE").value] = Value.int(MULTILINE)

      source_sym = interp.symbols.intern("__source").value
      options_sym = interp.symbols.intern("__options").value

      # `Regexp.new(pattern_or_regexp, options = 0)` — the constructor
      # form, alongside `/pattern/flags` literal syntax (see
      # VM#make_regexp_object, which shares `compile_regex` with this).
      # Mirrors the mruby fixture's "Regexp.new with regexp" case: given
      # an existing Regexp, copies its source/options rather than
      # treating it as a pattern string.
      define_singleton(cls, interp, "new") do |args, _blk, ncc|
        first = args[1]? || Value.nil_value
        pattern, flags =
          if (robj = first.as_robject?) && robj.is_a?(RegexpObject)
            {robj.ivars[source_sym].as_string, robj.ivars[options_sym].as_int.to_i32}
          else
            {first.as_string, (args[2]?.try(&.as_int.to_i32) || 0)}
          end
        regex = compile_regex(pattern, flags, ncc)
        obj = RegexpObject.new(cls, regex)
        obj.ivars[source_sym] = Value.string(pattern)
        obj.ivars[options_sym] = Value.int(flags)
        Value.robject(obj)
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

      # `#match(str)` — real Ruby returns a MatchData on success, nil
      # on no match, and raises if `str` is missing entirely (R022;
      # deliberately a fresh code rather than reusing R018/R019, since
      # those two are worded around String's own pattern-taking
      # methods specifically — "no pattern argument" reads wrong for
      # "no string to match against"). A non-String argument is
      # coerced via #to_s in real Ruby for anything that responds to
      # it; Adjutant requires a String outright for now (same
      # String-first scoping already applied to #source/#options
      # above), raising the same R022 rather than silently doing
      # nothing.
      define(cls, interp, "match") do |args, _blk, ncc|
        robj = args.first.as_robject.as(RegexpObject)
        str = args[1]?.try(&.as_string?)
        ncc.raise_error("R022", {"method" => "match"}, "ArgumentError") unless str
        if md = robj.regex.match(str)
          make_match_data(interp, md, str)
        else
          Value.nil_value
        end
      end

      # `#match?(str)` — same search as #match, but a plain Bool and
      # no MatchData allocation; real Ruby's own documented reason for
      # this method existing alongside #match at all.
      define(cls, interp, "match?") do |args, _blk, ncc|
        robj = args.first.as_robject.as(RegexpObject)
        str = args[1]?.try(&.as_string?)
        ncc.raise_error("R022", {"method" => "match?"}, "ArgumentError") unless str
        Value.bool(robj.regex.matches?(str))
      end

      # `#=~` is NOT defined here, deliberately, not merely deferred:
      # unlike `#===` (real dispatch via case/when's compiler-generated
      # `Op::Call`, or callable directly as `.===(x)` — TripleEq is a
      # real token wherever `===` appears, so the dot-call form parses
      # fine even though bare infix `a === b` doesn't) `=~` has no
      # infix support (no PRECEDENCE entry, and no combined `=~` token
      # at all — see UNSUPPORTED.md — so it lexes as separate `Eq`/
      # `Tilde` tokens) AND no working dot-call spelling either, since
      # `.=~(x)` would grab only the `=` as the method name and choke
      # on the leftover `~`. A native method here would be genuinely
      # unreachable from any script syntax today — dead surface, not a
      # real feature — so it's left out rather than shipped unusable.
      # Real Ruby's `#=~` also sets the `$~`/`$1`.. globals as a side
      # effect, which is separate, real, not-yet-existing machinery
      # anyway (no `$`-global plumbing in Adjutant at all yet). Revisit
      # together if/when a real `=~` token and infix precedence entry
      # are ever added.

      # `#===` — case/when and Enumerable#grep dispatch through this.
      # Real Ruby returns false (not a TypeError) for a non-String
      # right-hand side, so a bad `args[1]` is a false result here too,
      # not a raised error — case/when trying every `when` clause in
      # turn depends on a mismatched type just not matching, not
      # blowing up the whole case statement.
      define(cls, interp, "===") do |args, _blk, _ncc|
        robj = args.first.as_robject.as(RegexpObject)
        str = args[1]?.try(&.as_string?)
        Value.bool(str ? robj.regex.matches?(str) : false)
      end

      cls
    end

    # Shared by Regexp#match and (once String dispatch grows a Regexp
    # branch) String#match — builds a real MatchData RubyObject from a
    # Crystal ::Regex::MatchData, looking up the MatchData RubyClass
    # by name (find_builtin_class) rather than threading it through
    # every call site, since bootstrap_regexp and bootstrap_match_data
    # register independently and neither needs to know the other's
    # registration order — this is a call-time lookup, and by the time
    # any script can actually call #match, every builtin class is long
    # since registered.
    def self.make_match_data(interp : Interpreter, md : ::Regex::MatchData, subject : String) : Value
      cls = interp.find_builtin_class("MatchData")
      raise "MatchData class not registered — bootstrap_match_data must run before any script executes" unless cls
      Value.robject(MatchDataObject.new(cls, md, subject))
    end

    def self.bootstrap_match_data(interp : Interpreter) : RubyClass
      cls = RubyClass.new("MatchData")

      # Every ::Regex::MatchData method used below (#[], #[]?,
      # #pre_match, #post_match, #begin) is used from memory, same
      # "not independently verified against a toolchain here" caveat
      # as Builtins.regex_options above — flag any compile mismatch
      # and this gets corrected on the spot.
      # `#[](n)` — indexed (0 = whole match, 1.. = capture groups) or
      # named (String/Symbol) access. Real Ruby raises IndexError for
      # an out-of-range integer index and returns nil for a group that
      # simply didn't participate in the match (e.g. the losing side
      # of an alternation) — Crystal's `::Regex::MatchData#[]?`
      # collapses both to nil, which is close enough for a lean first
      # cut (see the phase's own "smaller first cut, useful for common
      # cases" scoping) but is a real, worth-noting divergence from
      # real Ruby's IndexError case specifically.
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
        result ? Value.string(result) : Value.nil_value
      end

      define(cls, interp, "to_s") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.md[0])
      end

      define(cls, interp, "pre_match") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.md.pre_match)
      end

      define(cls, interp, "post_match") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.md.post_match)
      end

      define(cls, interp, "string") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        Value.string(obj.subject)
      end

      define(cls, interp, "begin") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        n = args[1]?.try(&.as_int.to_i) || 0
        pos = obj.md.begin(n)
        pos ? Value.int(pos.to_i64) : Value.nil_value
      end

      cls
    end
  end
end
