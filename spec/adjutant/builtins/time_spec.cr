require "../../spec_helper"

module Adjutant
  describe "Time" do
    describe "construction" do
      it "Time.now returns a Time-classed instance" do
        eval("Time.now.class.to_s").as_string.should eq "Time"
      end

      it "Time.at(seconds) with an Integer" do
        eval("Time.at(2).to_i").as_int.should eq 2
      end

      it "Time.at(seconds) with a Float, sub-second precision preserved" do
        eval("Time.at(2.5).to_f").as_float.should be_close(2.5, 0.000001)
      end

      it "Time.at raises FloatDomainError (R034) on NaN" do
        error = expect_raises(RuntimeError) do
          eval("Time.at(0.0 / 0.0)")
        end
        error.diagnostic.not_nil!.code.should eq("R034")
      end

      it "Time.at raises FloatDomainError (R034) on Infinity" do
        expect_raises(RuntimeError) do
          eval("Time.at(1.0 / 0.0)")
        end
      end

      it "Time.gm builds a UTC time from year/month/day/hour/min/sec" do
        eval(<<-RUBY).as_string.should eq "2012-9-23-0-0-0"
        t = Time.gm(2012, 9, 23)
        "\#{t.year}-\#{t.month}-\#{t.day}-\#{t.hour}-\#{t.min}-\#{t.sec}"
        RUBY
      end

      it "Time.utc is an alias for Time.gm" do
        eval(<<-RUBY).as_string.should eq "2034-1-1"
        t = Time.utc(2034)
        "\#{t.year}-\#{t.month}-\#{t.day}"
        RUBY
      end

      it "Time.local builds a local time from year/month/day/hour" do
        eval(<<-RUBY).as_string.should eq "2014-12-27-18-0-0"
        t = Time.local(2014, 12, 27, 18)
        "\#{t.year}-\#{t.month}-\#{t.day}-\#{t.hour}-\#{t.min}-\#{t.sec}"
        RUBY
      end

      it "Time.mktime is an alias for Time.local" do
        eval(<<-RUBY).as_string.should eq "2013-10-4-6-15-58"
        t = Time.mktime(2013, 10, 4, 6, 15, 58)
        "\#{t.year}-\#{t.month}-\#{t.day}-\#{t.hour}-\#{t.min}-\#{t.sec}"
        RUBY
      end
    end

    describe "component accessors" do
      it "year/month/mon/day/mday/hour/min/sec all read back what was constructed" do
        eval(<<-RUBY).as_bool.should eq true
        t = Time.gm(2012, 12, 23, 7, 6, 40)
        t.year == 2012 && t.month == 12 && t.mon == 12 &&
          t.day == 23 && t.mday == 23 && t.hour == 7 &&
          t.min == 6 && t.sec == 40
        RUBY
      end

      it "wday: Sunday is 0 (real Ruby convention, not Crystal's Monday=1..Sunday=7)" do
        eval("Time.gm(2012, 12, 23).wday").as_int.should eq 0
      end

      it "monday is 1" do
        eval("Time.gm(2012, 12, 24).wday").as_int.should eq 1
      end

      it "yday" do
        eval("Time.gm(2012, 12, 23).yday").as_int.should eq 358
      end
    end

    describe "arithmetic and comparison" do
      it "t + seconds advances the time" do
        eval(<<-RUBY).as_string.should eq "2011-3-13 7:7:40 UTC"
        t = Time.at(1300000000) + 60
        t = t.utc
        "\#{t.year}-\#{t.month}-\#{t.day} \#{t.hour}:\#{t.min}:\#{t.sec} \#{t.utc? ? "UTC" : "?"}"
        RUBY
      end

      it "t - seconds moves the time back" do
        eval(<<-RUBY).as_int.should eq 1299999940
        t = Time.at(1300000000) - 60
        t.to_i
        RUBY
      end

      it "t1 - t2 (Time minus Time) returns a Float of elapsed seconds" do
        eval("Time.at(1300000060) - Time.at(1300000000)").as_float.should be_close(60.0, 0.000001)
      end

      it "<=> orders three times correctly, and against nil is nil" do
        eval(<<-RUBY).as_bool.should eq true
        t1 = Time.at(1300000000)
        t2 = Time.at(1400000000)
        t3 = Time.at(1500000000)
        (t2 <=> t1) == 1 && (t2 <=> t2) == 0 && (t2 <=> t3) == -1 && (t2 <=> nil).nil?
        RUBY
      end

      it "< and > dispatch through <=> for free (Comparable-style — see DEVELOPMENT.md)" do
        eval("Time.at(1) < Time.at(2)").as_bool.should eq true
        eval("Time.at(2) > Time.at(1)").as_bool.should eq true
      end

      it "== is TRUE for two distinct Time objects representing the same instant — value equality via <=>, not identity" do
        eval("Time.at(1300000000) == Time.at(1300000000)").as_bool.should eq true
      end

      it "== is false for different instants" do
        eval("Time.at(1000000000, 123456) == Time.at(1000000000, 123457)").as_bool.should eq false
      end
    end

    describe "zone handling" do
      it "utc/gmtime mutate self and return self, flipping utc?" do
        eval(<<-RUBY).as_bool.should eq true
        t = Time.now
        result = t.gmtime
        result.utc? && t.utc? && result.equal?(t)
        RUBY
      end

      it "getutc/getgm return a NEW Time (not the same object) representing the same instant, now in UTC" do
        eval(<<-RUBY).as_bool.should eq true
        t1 = Time.local(2000, 1, 1)
        t2 = t1.getutc
        !t1.equal?(t2) && t2.utc? && t2.to_i == t1.to_i
        RUBY
      end

      it "getlocal round-trips a UTC time to the same instant, in the local zone" do
        eval(<<-RUBY).as_bool.should eq true
        t1 = Time.utc(2014, 5, 6)
        t2 = t1.getlocal
        t2.to_i == t1.to_i
        RUBY
      end

      it "utc_offset is zero for a UTC time" do
        eval("Time.utc(2000, 1, 1).utc_offset").as_int.should eq 0
      end

      it "gmt_offset and gmtoff are aliases of utc_offset" do
        eval(<<-RUBY).as_bool.should eq true
        t = Time.utc(2000, 1, 1)
        t.utc_offset == t.gmt_offset && t.gmt_offset == t.gmtoff
        RUBY
      end

      it "zone is \"UTC\" for a UTC time" do
        eval("Time.at(1300000000).utc.zone").as_string.should eq "UTC"
      end

      it "dst? is always false — no real DST database, matching mruby-time's own scoping" do
        eval("Time.gm(2012, 12, 23).dst?").as_bool.should eq false
      end
    end

    describe "formatting" do
      it "to_s renders \"YYYY-MM-DD HH:MM:SS UTC\" for a UTC time" do
        eval("Time.gm(2003, 4, 5, 6, 7, 8).to_s").as_string.should eq "2003-04-05 06:07:08 UTC"
      end

      it "inspect renders a numeric +0000 offset even for UTC — not the \"UTC\" literal to_s uses" do
        eval("Time.gm(2003, 4, 5, 6, 7, 8).inspect").as_string.should eq "2003-04-05 06:07:08 +0000"
      end
    end

    describe "day-of-week predicates" do
      it "exactly one of sunday?..saturday? is true, matching wday" do
        eval(<<-RUBY).as_bool.should eq true
        t = Time.gm(2012, 12, 24) # a Monday
        !t.sunday? && t.monday? && !t.tuesday? && !t.wednesday? &&
          !t.thursday? && !t.friday? && !t.saturday?
        RUBY
      end
    end
  end
end
