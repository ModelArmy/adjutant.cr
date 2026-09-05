require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

# A Time instance's real state: Crystal's own `::Time`, mutable (not
# `getter`, `property`) because real Ruby's `#utc`/`#gmtime`/
# `#localtime` mutate self and return it — same subclassing rationale
# as RegexpObject/MatchDataObject (regexp.cr): no `Value` variant
# exists for a Crystal `::Time`, so it gets a real typed field here
# instead of living in `ivars`.
module Adjutant
  class TimeObject < RubyObject
    property time : ::Time

    def initialize(rclass : RubyClass, @time : ::Time)
      super(rclass)
    end
  end

  module Builtins
    # NOTE ON VERIFICATION: every Crystal `::Time`/`::Time::Span`
    # method name below (`.utc`, `.local`, `.unix`, `#to_unix`,
    # `#to_unix_f`, `#day_of_week`, `#zone`, `#offset`, `#to_utc`,
    # `#to_local`, ...) is written from recollection of Crystal's
    # stdlib API, NOT independently confirmed against a live toolchain
    # in this environment — same caveat `builtins/regexp.cr` already
    # flags for `::Regex::Options`. If `ops test`/`ops build` reports
    # an unknown method or wrong arity anywhere in this file, this
    # comment is the first place to look; the Ruby-facing method names
    # and their SEMANTICS (below) are the part actually specified and
    # tested against — the Crystal call underneath is an
    # implementation detail free to be corrected without changing this
    # file's public shape.
    #
    # SCOPE, chosen against mruby-time's own test suite
    # (mrbgems/mruby-time/test/time.rb) as the reference subset rather
    # than full MRI `Time` — mruby-time is itself a deliberately
    # scoped-down `Time`, which is the right reference point for an
    # embedded, small-model-facing language the same way Adjutant
    # itself is. Included: construction (`.now`, `.at`, `.utc`/`.gm`,
    # `.local`/`.mktime`), component accessors, `+`/`-`/`<=>` (and
    # everything Comparable derives from `<=>` for free — see
    # VM#values_equal?/#compare), zone handling, `#to_s`/`#inspect`,
    # day-of-week predicates. Deliberately EXCLUDED, matching
    # mruby-time's own scoping (its test file marks these "ATM not
    # implemented" or omits them outright): `#strftime` (a real Ruby
    # stdlib addition, not core `Time`, and not in mruby-time at all),
    # a real DST database (`#dst?` is a fixed `false`, same as
    # mruby-time), named timezones beyond UTC/local, `#asctime`/
    # `#ctime`, `#nsec`/`#tv_nsec` (sub-microsecond precision nothing
    # in Legate has a use for).
    def self.bootstrap_time(interp : Interpreter) : RubyClass
      cls = RubyClass.new("Time")

      define_singleton(cls, interp, "now") do |args|
        Value.robject(TimeObject.new(args.first.as_rclass, ::Time.local))
      end

      # `Time.at(seconds, usec = 0)` — `seconds` may be an Integer or
      # a Float (sub-second precision); `usec`, if given, is an
      # additional microsecond offset (real Ruby: `Time.at(0,
      # 500_000)` == half a second past the epoch). Real Ruby raises
      # FloatDomainError on a non-finite Float in either position —
      # R034 (ERRORS.md), same class Float#to_i's R016 raises.
      define_singleton(cls, interp, "at") do |args, _blk, ncc|
        seconds = numeric_arg_to_f64(args[1]? || Value.nil_value, ncc)
        usec = args[2]?.try { |v| numeric_arg_to_f64(v, ncc) } || 0.0
        t = ::Time.unix(0) + seconds_span(seconds) + (usec * 1_000).round.to_i64.nanoseconds
        Value.robject(TimeObject.new(args.first.as_rclass, t))
      end

      # `Time.utc(year, month=1, day=1, hour=0, min=0, sec=0)`,
      # `.gm` an alias — and `.local`/`.mktime` the same shape in the
      # local timezone. Sharing one implementation (`kind` fixed per
      # registration, not a runtime branch) since the six positional
      # arguments and their defaults are identical either way; only
      # which Crystal constructor gets called differs. Body extracted
      # to `time_from_ymdhms` (below) — this loop alone pushed
      # `bootstrap_time`'s own cyclomatic complexity over ameba's
      # limit; every arg-default `.try(&...) || n` and the `utc ? :`
      # branch count against the ENCLOSING method for a block defined
      # inline, not just this one.
      {"utc" => true, "gm" => true, "local" => false, "mktime" => false}.each do |name, utc|
        define_singleton(cls, interp, name) do |args, _blk, _ncc|
          Value.robject(TimeObject.new(args.first.as_rclass, time_from_ymdhms(args, utc)))
        end
      end

      define(cls, interp, "year") { |args| Value.int(time_of(args).year) }
      define(cls, interp, "month") { |args| Value.int(time_of(args).month) }
      define(cls, interp, "mon") { |args| Value.int(time_of(args).month) }
      define(cls, interp, "day") { |args| Value.int(time_of(args).day) }
      define(cls, interp, "mday") { |args| Value.int(time_of(args).day) }
      define(cls, interp, "hour") { |args| Value.int(time_of(args).hour) }
      define(cls, interp, "min") { |args| Value.int(time_of(args).minute) }
      define(cls, interp, "sec") { |args| Value.int(time_of(args).second) }
      define(cls, interp, "usec") { |args| Value.int(time_of(args).nanosecond // 1_000) }

      # Real Ruby's #wday: Sunday=0 .. Saturday=6. Crystal's
      # Time::DayOfWeek enum is Monday=1 .. Sunday=7 (ISO 8601 order,
      # NOT independently verified — see this file's own top-of-file
      # caveat) — `% 7` maps Sunday's 7 to Ruby's 0 and leaves
      # Monday..Saturday (1..6) unchanged either way.
      define(cls, interp, "wday") { |args| Value.int(time_of(args).day_of_week.value % 7) }
      define(cls, interp, "yday") { |args| Value.int(time_of(args).day_of_year) }

      define(cls, interp, "to_i") { |args| Value.int(time_of(args).to_unix) }
      define(cls, interp, "to_f") { |args| Value.float(time_of(args).to_unix_f) }

      # `t + seconds` -> Time. Real Ruby raises FloatDomainError for a
      # non-finite `seconds` — same R034 as Time.at, above.
      define(cls, interp, "+") do |args, _blk, ncc|
        new_t = time_of(args) + seconds_span(numeric_arg_to_f64(args[1]? || Value.nil_value, ncc))
        Value.robject(TimeObject.new(args.first.as_robject.rclass, new_t))
      end

      # `t - seconds` -> Time, but `t - other_time` -> Float (the
      # difference in seconds) — real Ruby's own overload on the
      # argument's type, not two different method names. Body
      # extracted to `time_sub` (below) — same complexity-budget
      # reasoning as `time_from_ymdhms` above; the `if`/`&&` branch
      # inline here was enough on its own to matter.
      define(cls, interp, "-") do |args, _blk, ncc|
        time_sub(args, ncc)
      end

      # The one method every other comparison (`<`, `<=`, `>`, `>=`,
      # and now `==` too — see VM#values_equal?'s `<=>`-derivation,
      # DEVELOPMENT.md's "Comparison operators" section) rides on for
      # free once this is defined; Time itself only needs to provide
      # this one. Returns nil for a non-Time argument, matching real
      # Ruby's own `<=>` contract (an unorderable pair is `nil`, not a
      # raise — the raise, if any, happens one layer up in `<`/`<=`/
      # `>`/`>=`'s own R013 check, not here).
      define(cls, interp, "<=>") do |args|
        time_spaceship(args)
      end

      # `#utc`/`#gmtime` mutate self to the UTC representation of the
      # SAME instant and return self; `#localtime` mutates to local.
      # `#getutc`/`#getgm`/`#getlocal` return a NEW Time in that zone,
      # leaving the receiver untouched — the "get" prefix is real
      # Ruby's own naming for the non-mutating pair.
      {"utc" => true, "gmtime" => true, "localtime" => false}.each do |name, to_utc|
        define(cls, interp, name) do |args|
          obj = args.first.as_robject.as(TimeObject)
          obj.time = zoned(obj.time, to_utc)
          args.first
        end
      end

      {"getutc" => true, "getgm" => true, "getlocal" => false}.each do |name, to_utc|
        define(cls, interp, name) do |args|
          Value.robject(TimeObject.new(args.first.as_robject.rclass, zoned(time_of(args), to_utc)))
        end
      end

      define(cls, interp, "utc?") { |args| Value.bool(time_of(args).utc?) }
      define(cls, interp, "gmt?") { |args| Value.bool(time_of(args).utc?) }
      define(cls, interp, "dst?") { |_args| Value.bool(false) } # no real DST database — same fixed `false` mruby-time itself gives (see file-top scope note)

      define(cls, interp, "zone") { |args| Value.string(time_of(args).zone.name) }
      define(cls, interp, "utc_offset") { |args| Value.int(time_of(args).offset) }
      define(cls, interp, "gmt_offset") { |args| Value.int(time_of(args).offset) }
      define(cls, interp, "gmtoff") { |args| Value.int(time_of(args).offset) }

      # Real Ruby: `#to_s` special-cases exactly-UTC as the literal
      # "UTC" suffix; any other zone (including local) shows a numeric
      # `+HHMM`/`-HHMM` offset instead. `#inspect` always shows the
      # numeric offset, UTC included (confirmed against the mruby-time
      # test fixture's own inspect pattern, which expects
      # `[+-][0-9]{4}` even for a value it never claims is UTC).
      define(cls, interp, "to_s") do |args|
        t = time_of(args)
        Value.string("#{format_datetime(t)} #{t.utc? ? "UTC" : format_offset(t)}")
      end

      define(cls, interp, "inspect") do |args|
        t = time_of(args)
        Value.string("#{format_datetime(t)} #{format_offset(t)}")
      end

      {"sunday?" => 0, "monday?" => 1, "tuesday?" => 2, "wednesday?" => 3,
       "thursday?" => 4, "friday?" => 5, "saturday?" => 6}.each do |name, wday|
        define(cls, interp, name) do |args|
          Value.bool(time_of(args).day_of_week.value % 7 == wday)
        end
      end

      cls
    end

    # Shared receiver-unwrap for every instance method above — DRYs
    # out the repeated `args.first.as_robject.as(TimeObject).time`
    # that regexp.cr's own methods write out in full each time (no
    # equivalent helper existed there since RegexpObject/MatchDataObject
    # methods are each more individually distinct; Time's accessor
    # methods are numerous and near-identical enough that the
    # duplication was worse than a one-line helper).
    private def self.time_of(args : Array(Value)) : ::Time
      args.first.as_robject.as(TimeObject).time
    end

    # `Time.at`/`#+`/`#-` all accept either an Integer or a Float
    # seconds argument, and all three must raise R034/FloatDomainError
    # on a non-finite Float — shared here rather than tripled.
    private def self.numeric_arg_to_f64(v : Value, ncc : NativeCallContext) : Float64
      f = v.float? ? v.as_float : v.as_int.to_f64
      unless f.finite?
        ncc.raise_error("R034", {"value" => f.to_s}, "FloatDomainError")
      end
      f
    end

    # `#+`/`#-`'s shared whole/fractional-nanosecond split — a
    # `Time::Span` built this way, rather than via Crystal's own
    # `Number#seconds` on the raw Float directly, keeps each `+`/`-`
    # call's nanosecond delta exact (rounded once here) rather than
    # letting float64 representation error in the SECONDS value
    # itself creep into the Time's internal nanosecond-precision
    # state on repeated accumulation (see "2000 times 500us make a
    # second" in spec/scripts/mruby/time.rb, which specifically
    # exercises this).
    private def self.seconds_span(seconds : Float64) : ::Time::Span
      whole = seconds.floor.to_i64
      frac_ns = ((seconds - whole) * 1_000_000_000).round.to_i64
      ::Time::Span.new(seconds: whole, nanoseconds: frac_ns)
    end

    # `Time.utc`/`.gm`/`.local`/`.mktime`'s shared body — see the
    # call site's own comment (bootstrap_time) for why this needed
    # extracting at all (ameba's CyclomaticComplexity, not a design
    # preference). `args[0]` is the receiver (the class); `args[1..6]`
    # are year..sec, defaulted the same way real Ruby defaults a
    # trailing omitted component (year has no default — a script
    # calling this with zero args gets whatever `as_int` on a missing
    # Value does, matching every other native method's "no arity
    # enforcement" convention — SCOPE.md).
    private def self.time_from_ymdhms(args : Array(Value), utc : Bool) : ::Time
      y = args[1]?.try(&.as_int.to_i32) || 1
      mo = args[2]?.try(&.as_int.to_i32) || 1
      d = args[3]?.try(&.as_int.to_i32) || 1
      h = args[4]?.try(&.as_int.to_i32) || 0
      mi = args[5]?.try(&.as_int.to_i32) || 0
      s = args[6]?.try(&.as_int.to_i32) || 0
      utc ? ::Time.utc(y, mo, d, h, mi, s) : ::Time.local(y, mo, d, h, mi, s)
    end

    # `#-`'s own body — real Ruby overloads on the ARGUMENT's type
    # (`Time - Time` -> Float elapsed seconds; `Time - Numeric` ->
    # Time), which is exactly the branch that pushed
    # `bootstrap_time`'s complexity over budget when written inline.
    private def self.time_sub(args : Array(Value), ncc : NativeCallContext) : Value
      t = time_of(args)
      other = args[1]? || Value.nil_value
      if (other_robj = other.as_robject?) && (other_time = other_robj.as?(TimeObject))
        Value.float((t - other_time.time).total_seconds)
      else
        new_t = t - seconds_span(numeric_arg_to_f64(other, ncc))
        Value.robject(TimeObject.new(args.first.as_robject.rclass, new_t))
      end
    end

    # `#<=>`'s own body — see time_sub's comment for the same
    # complexity-budget reasoning.
    private def self.time_spaceship(args : Array(Value)) : Value
      t = time_of(args)
      other = args[1]? || Value.nil_value
      if (other_robj = other.as_robject?) && (other_time = other_robj.as?(TimeObject))
        Value.int((t <=> other_time.time).to_i64)
      else
        Value.nil_value
      end
    end

    # `#utc`/`#gmtime`/`#getutc`/`#getgm` vs `#localtime`/`#getlocal`
    # — the one ternary shared by both mutating and non-mutating
    # zone-change pairs.
    private def self.zoned(t : ::Time, utc : Bool) : ::Time
      utc ? t.to_utc : t.to_local
    end

    private def self.format_datetime(t : ::Time) : String
      "%04d-%02d-%02d %02d:%02d:%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]
    end

    private def self.format_offset(t : ::Time) : String
      off = t.offset
      sign = off < 0 ? '-' : '+'
      abs_min = off.abs // 60
      "%c%02d%02d" % [sign, abs_min // 60, abs_min % 60]
    end
  end
end
