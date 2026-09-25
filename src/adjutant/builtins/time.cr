require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

# A Time's state: Crystal's `::Time`, which has no Value variant.
# Writable, since `utc`, `gmtime` and `localtime` change the receiver
# in place and return it, as in Ruby.
module Adjutant
  class TimeObject < RubyObject
    property time : ::Time

    def initialize(rclass : RubyClass, @time : ::Time)
      super(rclass)
    end
  end

  module Builtins
    # Builds the `Time` class. The method set follows mruby-time's
    # (mrbgems/mruby-time/test/time.rb), not MRI's: construction
    # (`now`, `at`, `utc`/`gm`, `local`/`mktime`), component readers,
    # `+`, `-` and `<=>` (from which the comparisons and `==` derive),
    # zone changes, `to_s`, `inspect` and the day-of-week predicates.
    # Not included, as in mruby-time: `strftime`, a DST database
    # (`dst?` is always false), named zones other than UTC and local,
    # `asctime`, `ctime` and `nsec`.
    def self.bootstrap_time(interp : Interpreter) : RubyClass
      cls = RubyClass.new("Time")

      define_singleton(cls, interp, "now") do |args|
        Value.robject(TimeObject.new(args.first.as_rclass, ::Time.local))
      end

      # `Time.at(seconds, usec = 0)`; `seconds` may be a Float. A
      # non-finite value raises R034 (FloatDomainError).
      define_singleton(cls, interp, "at") do |args, _blk, ncc|
        seconds = numeric_arg_to_f64(args[1]? || Value.nil_value, ncc)
        usec = args[2]?.try { |v| numeric_arg_to_f64(v, ncc) } || 0.0
        t = ::Time.unix(0) + seconds_span(seconds) + (usec * 1_000).round.to_i64.nanoseconds
        Value.robject(TimeObject.new(args.first.as_rclass, t))
      end

      # `Time.utc(year, month = 1, day = 1, hour = 0, min = 0,
      # sec = 0)` and its alias `gm`; `local` and `mktime` take the same
      # arguments in the local zone.
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

      # Sunday 0 to Saturday 6. Crystal numbers Monday 1 to Sunday 7,
      # so `% 7`.
      define(cls, interp, "wday") { |args| Value.int(time_of(args).day_of_week.value % 7) }
      define(cls, interp, "yday") { |args| Value.int(time_of(args).day_of_year) }

      define(cls, interp, "to_i") { |args| Value.int(time_of(args).to_unix) }
      define(cls, interp, "to_f") { |args| Value.float(time_of(args).to_unix_f) }

      # A Time `seconds` later. A non-finite value raises R034.
      define(cls, interp, "+") do |args, _blk, ncc|
        new_t = time_of(args) + seconds_span(numeric_arg_to_f64(args[1]? || Value.nil_value, ncc))
        Value.robject(TimeObject.new(args.first.as_robject.rclass, new_t))
      end

      # `t - seconds` is a Time; `t - other_time` is the difference in
      # seconds, as a Float.
      define(cls, interp, "-") do |args, _blk, ncc|
        time_sub(args, ncc)
      end

      # The comparisons and `==` derive from this. Nil for a non-Time
      # argument, as in Ruby.
      define(cls, interp, "<=>") do |args|
        time_spaceship(args)
      end

      # `utc`, `gmtime` and `localtime` change the receiver's zone and
      # return it; `getutc`, `getgm` and `getlocal` return a new Time.
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

      # `to_s` writes "UTC" for a UTC time and `+HHMM` otherwise;
      # `inspect` always writes the offset.
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

    # The receiver's `::Time`.
    private def self.time_of(args : Array(Value)) : ::Time
      args.first.as_robject.as(TimeObject).time
    end

    # A seconds argument as a Float64, Integer or Float, raising R034
    # for a non-finite one.
    private def self.numeric_arg_to_f64(v : Value, ncc : NativeCallContext) : Float64
      f = v.float? ? v.as_float : v.as_int.to_f64
      unless f.finite?
        ncc.raise_error("R034", {"value" => f.to_s}, "FloatDomainError")
      end
      f
    end

    # A span of `seconds`, split into whole seconds and nanoseconds
    # and rounded once, so repeated `+` doesn't accumulate Float error
    # (see "2000 times 500us make a second" in
    # spec/scripts/mruby/time.rb).
    private def self.seconds_span(seconds : Float64) : ::Time::Span
      whole = seconds.floor.to_i64
      frac_ns = ((seconds - whole) * 1_000_000_000).round.to_i64
      ::Time::Span.new(seconds: whole, nanoseconds: frac_ns)
    end

    # The body of `Time.utc` and `Time.local`. `args[0]` is the class;
    # `args[1..6]` are year to sec, all but year defaulted.
    private def self.time_from_ymdhms(args : Array(Value), utc : Bool) : ::Time
      y = args[1]?.try(&.as_int.to_i32) || 1
      mo = args[2]?.try(&.as_int.to_i32) || 1
      d = args[3]?.try(&.as_int.to_i32) || 1
      h = args[4]?.try(&.as_int.to_i32) || 0
      mi = args[5]?.try(&.as_int.to_i32) || 0
      s = args[6]?.try(&.as_int.to_i32) || 0
      utc ? ::Time.utc(y, mo, d, h, mi, s) : ::Time.local(y, mo, d, h, mi, s)
    end

    # The body of `Time#-`.
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

    # The body of `Time#<=>`.
    private def self.time_spaceship(args : Array(Value)) : Value
      t = time_of(args)
      other = args[1]? || Value.nil_value
      if (other_robj = other.as_robject?) && (other_time = other_robj.as?(TimeObject))
        Value.int((t <=> other_time.time).to_i64)
      else
        Value.nil_value
      end
    end

    # `t` in UTC or in the local zone.
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
