require "../../spec_helper"
require "file_utils"

private def with_tmpdir(&)
  path = File.join(Dir.tempdir, "adjutant-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

module Adjutant
  # No real `Legate.read` verb exists yet (step 5) — but per this
  # session's own decision, the broker is exercised through a
  # `Legate.read`-SHAPED trigger rather than a bare stub: this really
  # calls Broker#authorize_read and, if it doesn't raise, really
  # reads the file off disk and returns its labeled content. It is
  # deliberately NOT the polished verb step 5 will land (no
  # Legate::TooLarge on overflow, no Legate::Path argument
  # conversion) — just enough real behavior to prove the broker
  # actually gates a real effect, honestly, without pre-building the
  # verb surface this step isn't responsible for. Once the real
  # `Legate.read` lands, it's worth adding end-to-end coverage
  # alongside these that goes through it directly, same caveat
  # exceptions_spec.cr and value_types_spec.cr already carry for
  # their own throwaway triggers.
  private def self.interp_with_read_trigger(grants : Legate::Grants,
                                            risk_flow_policy : RiskFlowPolicy = TEST_REJECT_ALL_POLICY) : Interpreter
    interp, _ = make_interp(risk_flow_policy: risk_flow_policy)
    broker = Legate::Broker.new(grants)
    interp.modules.register("test/legate_read_trigger") do |i|
      i.define_native("legate_read_trigger") do |args, _blk, ncc|
        path = args[0].as_string
        broker.authorize_read(path, ncc)
        Value.string(File.read(path))
      end
    end
    interp.modules.require("test/legate_read_trigger", interp)
    interp
  end

  describe Legate::Broker do
    describe "#authorize_read — Grants layer" do
      it "allows a read under a granted root and returns the real file content" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "hello")
          grants = Legate::Grants.new(read_roots: [dir])
          interp = interp_with_read_trigger(grants)
          interp.eval(%(legate_read_trigger(#{(file).inspect}))).as_string.should eq "hello"
        end
      end

      it "denies a read outside every granted root with a FatalSignal, unrescuable by the script" do
        with_tmpdir do |dir|
          with_tmpdir do |other|
            file = File.join(other, "f.txt")
            File.write(file, "hello")
            grants = Legate::Grants.new(read_roots: [dir])
            interp = interp_with_read_trigger(grants)
            expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
              interp.eval(<<-RUBY)
              begin
                legate_read_trigger(#{(file).inspect})
              rescue Exception => e
                "swallowed"
              end
              RUBY
            end
          end
        end
      end

      it "denies with kind :denied specifically" do
        with_tmpdir do |dir|
          grants = Legate::Grants.new(read_roots: [dir])
          interp = interp_with_read_trigger(grants)
          begin
            interp.eval(%(legate_read_trigger(#{(File.join(dir, "missing.txt")).inspect})))
            fail "expected a FatalSignal"
          rescue ex : Legate::FatalSignal
            ex.kind.should eq :denied
          end
        end
      end

      it "denies with no roots granted at all" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "hello")
          interp = interp_with_read_trigger(Legate::Grants.deny_all)
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(legate_read_trigger(#{(file).inspect})))
          end
        end
      end
    end

    describe "#authorize_read — RiskFlowPolicy layer, reached only after Grants passes" do
      it "allows when Grants passes and the path carries no elevated sensitivity" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.txt")
          File.write(file, "hello")
          grants = Legate::Grants.new(read_roots: [dir])
          # A reject_all policy still allows Sensitivity::None content
          # through (action_for short-circuits before reject_all_flows
          # is even consulted) — this proves the dynamic layer doesn't
          # block a read Grants already approved, absent any matching
          # sensitivity rule.
          interp = interp_with_read_trigger(grants, RiskFlowPolicy.reject_all)
          interp.eval(%(legate_read_trigger(#{(file).inspect}))).as_string.should eq "hello"
        end
      end

      it "rejects via the SCRIPT-CATCHABLE RiskFlowRejectedError, not FatalSignal, once Grants has already passed" do
        with_tmpdir do |dir|
          file = File.join(dir, "secret.txt")
          File.write(file, "hello")
          grants = Legate::Grants.new(read_roots: [dir])
          policy = RiskFlowPolicy.new(
            sensitivity_patterns: [
              SensitivityPattern.new(ProvenanceKind::File, file, 10, Sensitivity::High),
            ],
            reject_all_flows: true,
          )
          interp = interp_with_read_trigger(grants, policy)
          # Script-catchable: a plain `rescue` DOES swallow this,
          # unlike the FatalSignal Grants denials above — proving the
          # two layers really do surface as the two different tiers
          # this session's design conversation described.
          interp.eval(<<-RUBY).as_string.should eq "swallowed"
          begin
            legate_read_trigger(#{(file).inspect})
          rescue
            "swallowed"
          end
          RUBY
        end
      end

      it "never reaches the RiskFlowPolicy layer at all when Grants denies first" do
        with_tmpdir do |dir|
          with_tmpdir do |other|
            file = File.join(other, "f.txt")
            File.write(file, "hello")
            grants = Legate::Grants.new(read_roots: [dir])
            # A policy that would ALLOW everything, if it were ever
            # consulted — proving the FatalSignal below comes from the
            # Grants gate, not from this (irrelevant, permissive)
            # dynamic policy.
            interp = interp_with_read_trigger(grants, RiskFlowPolicy.new)
            expect_raises(Legate::FatalSignal, /denied/) do
              interp.eval(%(legate_read_trigger(#{(file).inspect})))
            end
          end
        end
      end
    end

    describe "#log default" do
      # Regression coverage for a real bug, not a hypothetical one:
      # shipped 2026-09-08 claiming an unconfigured `Legate.log` was
      # a silent no-op ("matching Crystal's own 'unconfigured
      # sources emit nothing' default"), found wrong 2026-09-10 when
      # a real `ops test` run printed log lines to STDOUT from every
      # script that calls `Legate.log` without an embedder ever
      # configuring anything. Crystal's actual stdlib default is the
      # opposite of silent: Info-and-above logs to STDOUT for any
      # source on the GLOBAL default builder (`Log.builder`) unless
      # something in the process calls `Log.setup` — true of a plain
      # `::Log.for("adjutant.legate")`, which is what the broker used
      # to default to. The fix (`Legate::Broker::DEFAULT_LOG`) binds
      # the default to a PRIVATE `Log::Builder` with no bindings at
      # all, so there's genuinely nothing to reach — this test
      # exists so that fix can't silently regress back to the global
      # builder the way it shipped wrong the first time.
      it "is bound to a PRIVATE Log::Builder, not Crystal's shared global one" do
        Legate::Broker::DEFAULT_LOG_BUILDER.should_not eq(::Log.builder)
      end

      it "Legate::Broker.new with no log: argument uses that same default" do
        broker = Legate::Broker.new(Legate::Grants.deny_all)
        broker.log.should eq(Legate::Broker::DEFAULT_LOG)
      end

      it "Interpreter.new with no log: argument reaches the same default, " \
         "not a fresh ::Log.for(...) tied to the global builder" do
        interp, _ = make_interp
        interp.broker.log.should eq(Legate::Broker::DEFAULT_LOG)
      end
    end
  end
end
