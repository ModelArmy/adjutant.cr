require "../../spec_helper"

module Adjutant
  # No real Legate::Lines/Bytes/Records exist yet (the broker's job,
  # not built until a later step) — this registers a throwaway
  # concrete class that `include`s Legate::Stream and a native
  # `stream_of(*values)` trigger wrapping its arguments in an
  # in-memory Iterator(Value), purely to exercise the Stream protocol
  # in isolation ahead of any real source existing. Once a real stream
  # type lands, it's worth adding end-to-end coverage alongside these
  # that goes through it directly rather than this synthetic trigger.
  private def self.interp_with_test_stream : Interpreter
    interp, _ = make_interp
    interp.modules.register("test/legate_stream_trigger") do |i|
      legate = i.get_global("Legate").as_rclass
      stream_module = legate.constants[i.symbols.intern("Stream").value].as_rclass

      test_stream_cls = RubyClass.new("TestStream", nil, is_module: false)
      test_stream_cls.rclass = i.class_class
      test_stream_cls.included_modules << stream_module
      i.define_global_class(test_stream_cls)

      i.define_native("stream_of") do |args, _blk, _ncc|
        Value.robject(StreamObject.new(test_stream_cls, args.each))
      end

      # A dedicated trigger for the materialization-cap test — avoids
      # relying on script-level splat-call syntax (`f(*array)`),
      # which hasn't been confirmed supported here and is tangential
      # to what this specific test is actually checking.
      i.define_native("big_stream_of_size") do |args, _blk, _ncc|
        n = args.first.as_int.to_i32
        Value.robject(StreamObject.new(test_stream_cls, (0...n).each.map { |i| Value.int(i.to_i64) }))
      end
    end
    interp.modules.require("test/legate_stream_trigger", interp)
    interp
  end

  describe "Legate::Stream (phase 1)" do
    it "a TestStream instance is a real Legate::Stream via include, not a simulation" do
      interp = interp_with_test_stream
      interp.eval("stream_of(1, 2, 3).is_a?(Legate::Stream)").as_bool.should eq true
    end

    describe "map/select/reject (lazy operators) + each/to_a (terminals)" do
      it "map transforms every element" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        stream_of(1, 2, 3).map { |x| x * 10 }.to_a == [10, 20, 30]
        RUBY
      end

      it "select keeps only matching elements" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        stream_of(1, 2, 3, 4, 5).select { |x| x.even? }.to_a == [2, 4]
        RUBY
      end

      it "reject drops matching elements" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        stream_of(1, 2, 3, 4, 5).reject { |x| x.even? }.to_a == [1, 3, 5]
        RUBY
      end

      it "chains map/select/reject together, lazily — matches the worked example's shape (LEGATE.md §6.5)" do
        interp = interp_with_test_stream
        # Single line — Adjutant's parser doesn't support leading-dot
        # line-continuation for a method chain (confirmed: `.` can't
        # start an expression, P002), unlike real Ruby 1.9+.
        interp.eval(<<-RUBY).as_bool.should eq true
        stream_of(1, 2, 3, 4, 5, 6).select { |x| x.even? }.map { |x| x * 100 }.reject { |x| x > 400 }.to_a == [200, 400]
        RUBY
      end

      it "an operator with no block passes through unchanged, matching Array#map's own forgiving convention" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 3).map.to_a").as_array.to_a.map(&.as_int).should eq [1, 2, 3]
      end

      it "nothing runs until a terminal is called — laziness is real, not just a naming convention" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        calls = 0
        s = stream_of(1, 2, 3).map { |x| calls += 1; x }
        no_calls_yet = (calls == 0)
        s.to_a
        no_calls_yet && calls == 3
        RUBY
      end

      it "each returns self and invokes the block for every surviving element" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        seen = []
        result = stream_of(1, 2, 3).select { |x| x > 1 }.each { |x| seen << x }
        seen == [2, 3] && result.is_a?(Legate::Stream)
        RUBY
      end
    end

    describe "take (lazy operator, stops the whole chain)" do
      it "take(n) limits the stream to n elements" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 3, 4, 5).take(3).to_a").as_array.to_a.map(&.as_int).should eq [1, 2, 3]
      end

      it "take composes with map/select — the short-circuit happens after filtering, not before" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        stream_of(1, 2, 3, 4, 5, 6, 7, 8).select { |x| x.even? }.take(2).to_a == [2, 4]
        RUBY
      end

      it "take(n) genuinely stops pulling from the source — later elements are never even reached" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        pulled = []
        stream_of(1, 2, 3, 4, 5).map { |x| pulled << x; x }.take(2).to_a
        pulled == [1, 2]
        RUBY
      end
    end

    describe "sum/count (terminals)" do
      it "sum of integers stays an Integer" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 3).sum").as_int.should eq 6
      end

      it "sum involving a Float promotes the result to Float" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 2.5).sum").as_float.should be_close(5.5, 0.000001)
      end

      it "count counts surviving elements, after filtering" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 3, 4, 5).select { |x| x.even? }.count").as_int.should eq 2
      end
    end

    describe "first (terminal, both arities)" do
      it "first (no arg) returns the single first surviving element" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 3).select { |x| x > 1 }.first").as_int.should eq 2
      end

      it "first returns nil on an empty result" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 3).select { |x| x > 100 }.first").null?.should eq true
      end

      it "first(n) returns an Array of up to n elements" do
        interp = interp_with_test_stream
        interp.eval("stream_of(1, 2, 3, 4, 5).first(3)").as_array.to_a.map(&.as_int).should eq [1, 2, 3]
      end

      it "first(n) genuinely stops pulling once satisfied, same as take" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        pulled = []
        stream_of(1, 2, 3, 4, 5).map { |x| pulled << x; x }.first(2)
        pulled == [1, 2]
        RUBY
      end
    end

    describe "single-pass (LEGATE.md §6.1)" do
      it "iterating an already-exhausted stream again raises Legate::EOF (amended LEGATE.md §6.1) rather than silently returning nothing" do
        interp = interp_with_test_stream
        eval = interp.eval(<<-RUBY)
        s = stream_of(1, 2, 3)
        first_pass = s.to_a
        second_pass = begin
          s.to_a
          "no error raised"
        rescue Legate::EOF => e
          "eof: \#{e.message}"
        end
        [first_pass, second_pass]
        RUBY
        arr = eval.as_array.to_a
        arr[0].as_array.to_a.map(&.as_int).should eq [1, 2, 3]
        arr[1].as_string.should match(/^eof: /)
      end

      it "raises Legate::EOF on .each too, not just .to_a, once the source is exhausted" do
        interp = interp_with_test_stream
        eval = interp.eval(<<-RUBY)
        s = stream_of(1, 2)
        s.to_a
        begin
          s.each { |x| x }
          "no error raised"
        rescue Legate::EOF
          "eof"
        end
        RUBY
        eval.as_string.should eq "eof"
      end

      it "two streams derived from a common ancestor share pull position — real Ruby's own lazy-enumerator aliasing, not a bug" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_bool.should eq true
        s = stream_of(1, 2, 3, 4)
        a = s.select { |x| true }
        b = s.select { |x| true }
        first_two = a.first(2)
        rest = b.to_a
        first_two == [1, 2] && rest == [3, 4]
        RUBY
      end
    end

    describe "to_a's materialization cap (LEGATE.md §6.4)" do
      it "raises Legate::TooLarge over the cap" do
        interp = interp_with_test_stream
        interp.eval(<<-RUBY).as_string.should eq "caught"
        begin
          big_stream_of_size(100_001).to_a
        rescue Legate::TooLarge
          "caught"
        end
        RUBY
      end

      it "stays under the cap without raising" do
        interp = interp_with_test_stream
        # `.size`, not `.count` — Array#count doesn't exist in
        # Adjutant yet (a real, separate gap; see SCOPE.md).
        interp.eval("big_stream_of_size(10).to_a.size").as_int.should eq 10
      end
    end
  end
end
