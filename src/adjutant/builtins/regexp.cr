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
    getter regexp_value : Value

    def initialize(rclass : RubyClass, @md : ::Regex::MatchData, @subject : String, @regexp_value : Value)
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

    # Splits `adjutant_flags` into its enabled/disabled letter strings,
    # always in `m`, `i`, `x` order on both sides — the fixed order
    # real Ruby's own `Regexp#to_s`/`#inspect` use. Shared by both
    # methods (bootstrap_regexp, below) rather than each recomputing
    # it — `to_s` needs both halves, `inspect` only the enabled one.
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

    # Escapes a `/` in `pattern` as `\/`, UNLESS it's already preceded
    # by a `\` (see `Regexp#inspect`'s own comment, bootstrap_regexp,
    # for the full reasoning and the one known remaining edge case).
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
        # `first.label` seeds BOTH the constructed Regexp's own outer
        # label and the `__source` ivar directly — a String pattern's
        # taint (or, for the copy-constructor form, the SOURCE
        # Regexp's own label) has to survive into whatever
        # `#source` later returns, not just the object as a whole.
        # `#source`/`#options` (below) just return the stored ivar
        # value directly, so getting this right HERE is what makes
        # those correct — same "seed derived values from the source's
        # own label" principle DEVELOPMENT.md documents for
        # Array/Hash/Range's own container-labeling fix, applied here
        # to a Regexp's own pattern text. `__options` (a bitmask) is
        # deliberately left unlabeled, matching this codebase's own
        # established precedent that metadata about labeled data
        # (`String#length`/`#size`, a match position) doesn't itself
        # carry the label — only actual DATA extracted from a labeled
        # source does.
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

      # Confirmed against a real Ruby session (2026-08-17): `Regexp#
      # to_s` renders as `(?enabled-disabled:pattern)` — e.g. `/a/i.
      # to_s => "(?i-mx:a)"` — flag letters ALWAYS in `m`, `i`, `x`
      # order on both sides of the `-`, and the `-disabled` section
      # (dash included) OMITTED ENTIRELY when every flag is enabled
      # (no disabled flags left to list) — `/a/mix.to_s => "(?mix:a)"`,
      # no trailing `-`. `Regexp#inspect` is simpler: real source
      # syntax, `/pattern/enabledflags` — `/a/i.inspect => "/a/i"`.
      # `flag_letters` (below) computes both the enabled and disabled
      # letter strings once, shared by both methods, in the same
      # fixed order either format needs. All confirmed exactly as
      # implemented — no changes needed from the original assumption.
      #
      # `inspect` escapes an unescaped `/` inside the pattern as `\/`
      # — ALSO confirmed against that same real Ruby session
      # (`Regexp.new("a/b").inspect => "/a\/b/"`), a real gap in the
      # original version of this method, not left unhandled anymore.
      # `escape_slashes` (below) only escapes a `/` NOT already
      # preceded by a `\` — handles the confirmed case (a plain,
      # unescaped `/`) and leaves an already-escaped `\/` (e.g. from
      # `/a\/b/` literal syntax, where `#source` already stores the
      # escape as written) alone rather than double-escaping it.
      # Simple one-character lookback, not a full alternating-
      # backslash-run parser — a genuinely doubled backslash before a
      # slash (`a\\/b`, meaning a literal backslash followed by an
      # UNESCAPED slash) isn't independently confirmed to round-trip
      # correctly; flagged rather than guessed at further.
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
      #
      # WITH A BLOCK: real Ruby yields the MatchData itself (not just
      # the matched substring, unlike #sub/#gsub's own block form —
      # see UNSUPPORTED.md's U011 entry for why that distinction is
      # exactly what makes this method worth having a real block form
      # for) and returns the block's own return value in place of the
      # MatchData. The block is only invoked on an actual match — same
      # as real Ruby, which doesn't call it at all on a failed match.
      define(cls, interp, "match") do |args, blk, ncc|
        robj = args.first.as_robject.as(RegexpObject)
        str = args[1]?.try(&.as_string?)
        ncc.raise_error("R022", {"method" => "match"}, "ArgumentError") unless str
        if md = robj.regex.match(str)
          # Joins the SUBJECT string's own label with the Regexp's
          # own — a MatchData is fundamentally a view INTO the
          # subject (real data), so it inherits taint the same way a
          # sliced substring does (`exec_get_index_string_range`,
          # vm.cr); the Regexp's own label is joined too on the same
          # "when in doubt, join every plausible source" principle
          # DEVELOPMENT.md documents for Hash#merge's multi-source
          # case, in case the PATTERN itself was built from tainted
          # text (`/#{tainted}/`).
          match_label = RiskFlowLabel.join(args[1]?.try(&.label), args.first.label)
          match_data = make_match_data(interp, md, str, args.first, match_label)
          blk ? ncc.invoke(blk, [match_data]) : match_data
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
    # `label` is the caller's responsibility to compute (join of the
    # SUBJECT string's own label with the Regexp's own label — see
    # both call sites, Regexp#match and String#match) rather than
    # derived in here, since this helper only sees the already-matched
    # `::Regex::MatchData` and subject text, not the original labeled
    # `Value`s either came from.
    def self.make_match_data(interp : Interpreter, md : ::Regex::MatchData, subject : String,
                             regexp_value : Value, label : RiskFlowLabel?) : Value
      cls = interp.find_builtin_class("MatchData")
      raise "MatchData class not registered — bootstrap_match_data must run before any script executes" unless cls
      Value.robject(MatchDataObject.new(cls, md, subject, regexp_value), label)
    end

    # ameba:disable Metrics/CyclomaticComplexity - one `define` call per native method, each a flat independent case; count comes from many methods, not tangled branching
    def self.bootstrap_match_data(interp : Interpreter) : RubyClass
      cls = RubyClass.new("MatchData")

      # Every ::Regex::MatchData method used below (#[], #[]?,
      # #pre_match, #post_match, #begin) is used from memory, same
      # "not independently verified against a toolchain here" caveat
      # as Builtins.regex_options above — flag any compile mismatch
      # and this gets corrected on the spot.
      #
      # LABELING: every accessor here that returns an actual PIECE of
      # the subject (`#[]`, `#to_s`, `#pre_match`, `#post_match`,
      # `#string`, `#captures`) threads `args.first.label` — this
      # MatchData's OWN label, already the join of the subject's and
      # the Regexp's own labels (see Regexp#match/String#match's own
      # construction) — onto the returned Value, the same "a piece
      # extracted from a labeled source inherits its label" principle
      # `exec_get_index_string_range` (vm.cr, plain string slicing)
      # and the Array/Hash container-labeling fix (DEVELOPMENT.md)
      # both already establish. `#begin`/`#end` deliberately do NOT —
      # a match position is metadata about the data, not a piece of it,
      # matching this codebase's own existing precedent that
      # `String#length`/`#size` don't inherit the receiver's label
      # either.
      #
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

      # `#end` mirrors `#begin` exactly — same not-independently-
      # verified caveat on `::Regex::MatchData#end`'s exact name/
      # signature as the rest of this file's Crystal-API surface.
      define(cls, interp, "end") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        n = args[1]?.try(&.as_int.to_i) || 0
        pos = obj.md.end(n)
        pos ? Value.int(pos.to_i64) : Value.nil_value
      end

      # `#captures` — every numbered group's text (group 0, the whole
      # match, excluded — same as real Ruby), `nil` for a group that
      # didn't participate. Unlike the `1..9` cap `Regexp#match`'s own
      # backslash-ref capture population uses (a real Ruby syntax
      # limit specific to `\1`-`\9` replacement references), this
      # needs the PATTERN's real group count — real Ruby's own
      # `#captures` isn't capped at 9. `::Regex::MatchData#size`'s
      # exact semantics (total groups including group 0, per Crystal's
      # own docs as recalled) aren't independently verified against a
      # toolchain here; flag if `ops test` says otherwise.
      define(cls, interp, "captures") do |args|
        obj = args.first.as_robject.as(MatchDataObject)
        caps = (1...obj.md.size).map { |i| (c = obj.md[i]?) ? Value.string(c, args.first.label) : Value.nil_value }
        Value.new(LabeledArray.new(caps, args.first.label), nil)
      end

      # `#regexp` — the Regexp instance #match was called on, threaded
      # through from `Regexp#match` at construction time (see
      # `make_match_data`'s own `regexp_value` parameter).
      define(cls, interp, "regexp") do |args|
        args.first.as_robject.as(MatchDataObject).regexp_value
      end

      # Confirmed against a real Ruby session (2026-08-17):
      # `MatchData#inspect` renders as `#<MatchData "whole_match"
      # 1:"group1" 2:"group2">` — the whole match first, unlabeled,
      # then each capture group as `LABEL:"text"` (or bare
      # `LABEL:nil`, unquoted, for a group that didn't participate —
      # e.g. the losing side of an alternation), all SPACE-separated,
      # no commas — LABEL being the group's own NAME
      # (`/a(?<mid>b)c/.match("abc").inspect =>
      # '#<MatchData "abc" mid:"b">'`, confirmed) when it has one,
      # its numeric position otherwise. Both confirmed exactly as
      # implemented, except the named-group case, which the ORIGINAL
      # version of this method didn't attempt at all — fixed now,
      # using `::Regex#name_table` (a `Hash(Int32, String)`, capture
      # index to name, AS I RECALL Crystal's own API — NOT
      # independently verified against a toolchain here, same
      # standing caveat as this file's other `::Regex`/`::Regex::
      # MatchData` surface; if `ops test` reports an unknown method,
      # this is the first place to check) reached via the
      # already-stored `regexp_value` ivar, not a new field.
      #
      # NOT independently confirmed: what a PATTERN MIXING named and
      # unnamed capture groups renders as (does an unnamed group in
      # such a pattern still show its plain numeric position, or does
      # something else happen?) — only an ALL-named and an ALL-
      # unnamed pattern were tested. This implementation assumes the
      # straightforward per-group answer (named groups show their
      # name, unnamed ones their number, mixed freely) rather than
      # anything more exotic; worth a real check if a mixed pattern's
      # `inspect` output ever actually matters.
      #
      # Each piece of matched text is rendered via REAL dispatch on
      # `inspect` (`ncc.call_method`) rather than hand-rolled quote-
      # wrapping — reuses `String#inspect`'s own established escaping
      # (a matched substring containing a literal `"` or `\` needs the
      # same real quoting any other String does), not a second,
      # independent implementation of the same logic.
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
