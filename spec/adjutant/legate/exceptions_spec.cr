require "../../spec_helper"

module Adjutant
  # No Legate verb exists yet to raise a real FatalSignal from
  # script-observable behavior — used by the fatal-tier specs below to
  # register a throwaway native function that raises one directly,
  # exercising call_native's choke-point handling (and the dispatch
  # loop's own RuntimeError-only catch) in isolation, ahead of any real
  # verb needing to exist. Once Legate::rm (or any other grant-checked
  # verb) lands, it's worth adding an end-to-end spec alongside these
  # that goes through a REAL denied grant rather than this synthetic
  # trigger — this file should not be treated as sufficient coverage on
  # its own once that exists. Module-level (not nested inside a
  # `describe` block) since `def self.foo` inside a block defines on
  # whatever `self` the block runs with, not the enclosing module —
  # same reasoning as spec_helper.cr's own `make_interp`/`eval` helpers.
  private def self.interp_with_fatal_trigger(kind : Symbol) : Interpreter
    interp, _ = make_interp
    interp.modules.register("test/legate_fatal_trigger") do |i|
      i.define_native("trigger_fatal") do |_args, _blk, _ncc|
        raise Legate::FatalSignal.new(kind, "synthetic #{kind} for spec coverage")
      end
    end
    interp.modules.require("test/legate_fatal_trigger", interp)
    interp
  end

  describe "Legate exceptions" do
    describe "recoverable tier (Legate::Error < StandardError)" do
      it "Legate is a real module, reachable as a bare constant" do
        eval("Legate.class.to_s").as_string.should eq "Class"
      end

      it "Legate::NotFound is reachable via ConstPath and displays its fully-qualified name" do
        eval("Legate::NotFound.to_s").as_string.should eq "Legate::NotFound"
      end

      it "each of the seven recoverable classes is nested under Legate, not a flat global, and inherits Legate::Error" do
        eval(<<-RUBY).as_string.should eq "ok"
        [Legate::NotFound, Legate::Malformed, Legate::TooLarge, Legate::TooMany,
         Legate::Timeout, Legate::Transport, Legate::Conflict].each do |cls|
          raise "\#{cls} does not inherit Legate::Error" unless cls.superclass == Legate::Error
        end
        "ok"
        RUBY
      end

      it "Legate::NotFound is NOT reachable as a bare, unqualified constant — only via Legate::" do
        expect_raises(Exception) do
          eval("NotFound")
        end
      end

      it "raise Legate::NotFound, \"msg\" / rescue Legate::NotFound => e round-trips, same as any ordinary user-defined error" do
        eval(<<-RUBY).as_string.should eq "config.json missing"
        begin
          raise Legate::NotFound, "config.json missing"
        rescue Legate::NotFound => e
          e.message
        end
        RUBY
      end

      it "an unrescued Legate::Malformed propagates all the way up, same as any StandardError subclass" do
        expect_raises(Exception, /bad json/) do
          eval(<<-RUBY)
          raise Legate::Malformed, "bad json"
          RUBY
        end
      end

      it "a bare `rescue` (no class filter) catches Legate::TooLarge, since it's StandardError-rooted" do
        eval(<<-RUBY).as_string.should eq "caught"
        begin
          raise Legate::TooLarge, "too big"
        rescue
          "caught"
        end
        RUBY
      end

      it "rescue StandardError => e also catches a Legate error, via the real ancestor chain" do
        eval(<<-RUBY).as_string.should eq "caught"
        begin
          raise Legate::Timeout, "slow"
        rescue StandardError => e
          "caught"
        end
        RUBY
      end

      it "rescuing one Legate class does not catch an unrelated one" do
        expect_raises(Exception, /wrong host/) do
          eval(<<-RUBY)
          begin
            raise Legate::Transport, "wrong host"
          rescue Legate::NotFound
            "should not reach here"
          end
          RUBY
        end
      end
    end

    describe "fatal tier (Legate::FatalSignal — a plain Crystal Exception, not RuntimeError)" do
      it "propagates straight past rescue Exception => e — the exact case §9.2 exists to guarantee" do
        interp = interp_with_fatal_trigger(:denied)
        expect_raises(Legate::FatalSignal, /synthetic denied/) do
          interp.eval(<<-RUBY)
          begin
            trigger_fatal
          rescue Exception => e
            "swallowed"
          end
          RUBY
        end
      end

      it "propagates past a bare `rescue` with no class filter too" do
        interp = interp_with_fatal_trigger(:exhausted)
        expect_raises(Legate::FatalSignal, /synthetic exhausted/) do
          interp.eval(<<-RUBY)
          begin
            trigger_fatal
          rescue
            "swallowed"
          end
          RUBY
        end
      end

      it "propagates past several nested begin/rescue layers, same as it would past just one" do
        interp = interp_with_fatal_trigger(:aborted)
        expect_raises(Legate::FatalSignal, /synthetic aborted/) do
          interp.eval(<<-RUBY)
          begin
            begin
              begin
                trigger_fatal
              rescue Exception => e
                "innermost swallow attempt"
              end
            rescue StandardError => e
              "middle swallow attempt"
            end
          rescue
            "outer swallow attempt"
          end
          RUBY
        end
      end

      it "is NOT wrapped into an N001 diagnostic by call_native's catch-all — the real Crystal FatalSignal instance escapes unchanged, not a RuntimeError" do
        interp = interp_with_fatal_trigger(:denied)
        begin
          interp.eval("trigger_fatal")
          fail "expected Legate::FatalSignal to propagate"
        rescue ex : Legate::FatalSignal
          ex.kind.should eq :denied
        rescue ex : RuntimeError
          fail "FatalSignal was wrapped into a RuntimeError (#{ex.message}) — call_native's catch-all caught it before the explicit FatalSignal rescue clause did"
        end
      end

      it "carries kind and any diagnostic data through unchanged, for the run-log handler to read (LEGATE.md §8.6)" do
        interp, _ = make_interp
        interp.modules.register("test/legate_fatal_trigger_data") do |i|
          i.define_native("trigger_fatal_with_data") do |_args, _blk, _ncc|
            raise Legate::FatalSignal.new(:denied, "no grant", {"grant" => "delete", "path" => "/etc/passwd"})
          end
        end
        interp.modules.require("test/legate_fatal_trigger_data", interp)

        expect_raises(Legate::FatalSignal) do
          interp.eval("trigger_fatal_with_data")
        end

        begin
          interp.eval("trigger_fatal_with_data")
        rescue ex : Legate::FatalSignal
          ex.data["grant"].should eq "delete"
          ex.data["path"].should eq "/etc/passwd"
        end
      end
    end
  end
end
