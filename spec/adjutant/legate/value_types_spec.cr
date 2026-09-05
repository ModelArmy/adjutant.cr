require "../../spec_helper"

module Adjutant
  # Stat/Entry/Match/Response/Exit are broker-manufactured only — no
  # script-visible constructor (see each file's own comment). No real
  # broker/verb surface exists yet to produce one organically, so
  # these specs register a throwaway native module exposing each
  # type's `.build` directly, purely to exercise the accessor methods
  # in isolation ahead of the broker existing — the same pattern
  # exceptions_spec.cr used for FatalSignal. Once real verbs land,
  # it's worth adding end-to-end coverage alongside these that goes
  # through an actual verb call rather than this synthetic trigger.
  private def self.interp_with_value_type_triggers : Interpreter
    interp, _ = make_interp
    interp.modules.register("test/legate_value_type_triggers") do |i|
      legate = i.get_global("Legate").as_rclass

      i.define_native("make_stat") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Stat").value].as_rclass
        time_cls = i.get_global("Time").as_rclass
        now = Value.robject(TimeObject.new(time_cls, ::Time.local))
        Legate::Stat.build(i, cls, :file, 1024_i64, now, 0o644)
      end

      i.define_native("make_entry") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Entry").value].as_rclass
        path_cls = legate.constants[i.symbols.intern("Path").value].as_rclass
        path = Legate::Path.from_string(i, path_cls, "logs/app.log")
        time_cls = i.get_global("Time").as_rclass
        now = Value.robject(TimeObject.new(time_cls, ::Time.local))
        Legate::Entry.build(i, cls, path, :file, 2048_i64, now)
      end

      i.define_native("make_match") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Match").value].as_rclass
        path_cls = legate.constants[i.symbols.intern("Path").value].as_rclass
        path = Legate::Path.from_string(i, path_cls, "logs/app.log")
        Legate::Match.build(i, cls, path, 42_i64, "  raise SomethingBad", ["def foo"], ["end"])
      end

      i.define_native("make_response") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Response").value].as_rclass
        Legate::Response.build(i, cls, 200, {"Content-Type" => "application/json"},
          Value.string(%({"a": 1, "b": [true, null, 2.5]})), "https://example.com/final")
      end

      i.define_native("make_response_404") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Response").value].as_rclass
        Legate::Response.build(i, cls, 404, {} of String => String, Value.string("not found"), "https://example.com/missing")
      end

      i.define_native("make_exit") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Exit").value].as_rclass
        Legate::Exit.build(i, cls, 0, "hello\n", "", false, 0.42)
      end

      i.define_native("make_exit_failed") do |_args, _blk, _ncc|
        cls = legate.constants[i.symbols.intern("Exit").value].as_rclass
        Legate::Exit.build(i, cls, 1, "", "boom\n", false, 0.05)
      end
    end
    interp.modules.require("test/legate_value_type_triggers", interp)
    interp
  end

  describe "Legate value types" do
    describe "Legate::Path (§5.1 — the one type with a real public constructor)" do
      it "is reachable as Legate::Path and constructs via .new" do
        eval(%(Legate::Path.new("logs/app.log").class.to_s)).as_string.should eq "Legate::Path"
      end

      it "parts, absolute?, to_s round-trip a relative path" do
        eval(<<-RUBY).as_bool.should eq true
        p = Legate::Path.new("logs/app.log")
        p.parts == ["logs", "app.log"] && !p.absolute? && p.to_s == "logs/app.log"
        RUBY
      end

      it "handles an absolute path" do
        eval(<<-RUBY).as_bool.should eq true
        p = Legate::Path.new("/var/log/app.log")
        p.absolute? && p.to_s == "/var/log/app.log"
        RUBY
      end

      it "basename/ext/stem" do
        eval(<<-RUBY).as_bool.should eq true
        p = Legate::Path.new("logs/app.log")
        p.basename == "app.log" && p.ext == ".log" && p.stem == "app"
        RUBY
      end

      it "ext is empty for a dotfile with no other dot, and for no extension at all" do
        eval(<<-RUBY).as_bool.should eq true
        Legate::Path.new(".hidden").ext == "" && Legate::Path.new("README").ext == ""
        RUBY
      end

      it "parent drops the last component" do
        eval(%(Legate::Path.new("a/b/c").parent.to_s)).as_string.should eq "a/b"
      end

      it "/ joins a relative segment" do
        eval(%((Legate::Path.new("logs") / "app.log").to_s)).as_string.should eq "logs/app.log"
      end

      it "/ joins another Path" do
        eval(<<-RUBY).as_string.should eq "logs/2026/app.log"
        (Legate::Path.new("logs") / Legate::Path.new("2026/app.log")).to_s
        RUBY
      end

      it "/ raises Legate::Malformed on an absolute right-hand operand" do
        eval(<<-RUBY).as_string.should eq "caught"
        begin
          Legate::Path.new("logs") / "/etc/passwd"
        rescue Legate::Malformed
          "caught"
        end
        RUBY
      end

      it "/ raises Legate::Malformed on a \"..\" component" do
        eval(<<-RUBY).as_string.should eq "caught"
        begin
          Legate::Path.new("logs") / "../etc/passwd"
        rescue Legate::Malformed
          "caught"
        end
        RUBY
      end

      it "under? is true for a real descendant and inclusive of the root itself" do
        eval(<<-RUBY).as_bool.should eq true
        root = Legate::Path.new("work")
        child = Legate::Path.new("work/logs/app.log")
        child.under?(root) && root.under?(root)
        RUBY
      end

      it "under? is false for an unrelated path" do
        eval(<<-RUBY).as_bool.should eq false
        Legate::Path.new("other/app.log").under?(Legate::Path.new("work"))
        RUBY
      end
    end

    describe "Legate::Stat (§5.2)" do
      it "exposes type/size/mtime/mode and the file?/dir? predicates" do
        interp = interp_with_value_type_triggers
        # 420 decimal == 0o644 octal (the real Unix mode make_stat's
        # own Crystal-side Stat.build call constructs) — Adjutant's
        # lexer has no octal/hex/binary integer literal support at
        # all, so `0644` here would parse as plain decimal 644, not
        # octal 0644 — a real, separate gap, not something to route
        # around silently in this spec.
        interp.eval(<<-RUBY).as_bool.should eq true
        s = make_stat
        s.type == :file && s.size == 1024 && s.mode == 420 && s.file? && !s.dir?
        RUBY
      end

      it "mtime is a real Time" do
        interp = interp_with_value_type_triggers
        interp.eval("make_stat.mtime.class.to_s").as_string.should eq "Time"
      end
    end

    describe "Legate::Entry (§5.3)" do
      it "exposes path/type/size/mtime, path being a real Legate::Path" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_bool.should eq true
        e = make_entry
        e.path.class.to_s == "Legate::Path" && e.path.to_s == "logs/app.log" &&
          e.type == :file && e.size == 2048
        RUBY
      end
    end

    describe "Legate::Match (§5.4)" do
      it "exposes path/line_no/text/before/after" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_bool.should eq true
        m = make_match
        m.path.to_s == "logs/app.log" && m.line_no == 42 &&
          m.text == "  raise SomethingBad" && m.before == ["def foo"] && m.after == ["end"]
        RUBY
      end
    end

    describe "Legate::Response (§5.5)" do
      it "status/ok?/headers (downcased keys)/body/url" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_bool.should eq true
        r = make_response
        r.status == 200 && r.ok? && r.headers["content-type"] == "application/json" &&
          r.url == "https://example.com/final"
        RUBY
      end

      it "ok? is false for a 404, and raise! raises Legate::Transport" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_string.should eq "caught"
        r = make_response_404
        begin
          raise "should have raised" if r.ok?
          r.raise!
        rescue Legate::Transport
          "caught"
        end
        RUBY
      end

      it "raise! returns self when ok?" do
        interp = interp_with_value_type_triggers
        interp.eval("make_response.raise!.status").as_int.should eq 200
      end

      it "json parses the body into a real Hash, nested types included" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_bool.should eq true
        j = make_response.json
        j["a"] == 1 && j["b"] == [true, nil, 2.5]
        RUBY
      end

      it "json raises Legate::Malformed on invalid JSON" do
        interp, _ = make_interp
        interp.modules.register("test/legate_bad_json") do |i|
          legate = i.get_global("Legate").as_rclass
          i.define_native("make_bad_json_response") do |_args, _blk, _ncc|
            cls = legate.constants[i.symbols.intern("Response").value].as_rclass
            Legate::Response.build(i, cls, 200, {} of String => String, Value.string("not json"), "https://example.com")
          end
        end
        interp.modules.require("test/legate_bad_json", interp)
        interp.eval(<<-RUBY).as_string.should eq "caught"
        begin
          make_bad_json_response.json
        rescue Legate::Malformed
          "caught"
        end
        RUBY
      end
    end

    describe "Legate::Exit (§5.6)" do
      it "code/ok?/out/err/truncated?/duration" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_bool.should eq true
        e = make_exit
        e.code == 0 && e.ok? && e.out == "hello\n" && e.err == "" && !e.truncated?
        RUBY
      end

      it "raise! is a no-op (returns self) when ok?" do
        interp = interp_with_value_type_triggers
        interp.eval("make_exit.raise!.code").as_int.should eq 0
      end

      it "raise! raises Legate::NonZeroExit — NOT Legate::Transport (the spec bug fixed this session)" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_string.should eq "caught"
        begin
          make_exit_failed.raise!
        rescue Legate::NonZeroExit
          "caught"
        end
        RUBY
      end

      it "raise!'s NonZeroExit is NOT also a Legate::Transport (distinct branches of the recoverable tier)" do
        interp = interp_with_value_type_triggers
        interp.eval(<<-RUBY).as_string.should eq "correctly NOT transport"
        begin
          make_exit_failed.raise!
        rescue Legate::Transport
          "wrongly caught as transport"
        rescue Legate::NonZeroExit
          "correctly NOT transport"
        end
        RUBY
      end
    end
  end
end
