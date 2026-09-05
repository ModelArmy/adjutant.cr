require "../spec_helper"

# Does the Windows crash survive moving the server OUT of the process?
#
# ## Why this file exists, and why the standalone repros could not
#   answer it
#
# `spec/scratch/win_stream_crash_repro.cr` has been rewritten four
# times and has never crashed. So a FIFTH standalone program that
# survives would prove nothing — it would just be another survivor.
# The only artefact that has ever crashed is the spec binary.
#
# So this changes exactly ONE variable on the thing that does crash.
# Everything is kept: the VM, `Legate.fetch(stream: true)`, the raise
# inside the walk, the `ensure`-driven teardown, the `open_sources`
# assertion. The single difference from
# `verbs/fetch_stream_spec.cr`'s "closes the connection when the
# script raises mid-walk" is that the server is another OS PROCESS
# rather than a fiber on this thread.
#
# ## What each outcome means
#
#   crashes  -> the in-process server was never the cause. Real
#               deployments on Windows are affected: any script that
#               raises inside a streamed walk can terminate the host.
#               Blocking for Windows, and the upstream report no
#               longer needs HTTP::Server in it at all.
#   survives -> two servers sharing a thread matters, the crash is a
#               test-harness artefact, and production is probably
#               fine. Treat with some caution: an external Python
#               server also differs in chunking and close timing, so
#               a single survival is suggestive rather than proof —
#               it repeats below for that reason.
#
# ## Running it
#
# Needs a server already listening, and its port in the environment.
# CI starts Python's `http.server`; any static server serving a body
# of at least a few tens of KB will do. Skips itself when unset, so
# it is harmless in a normal run.
#
#   python -m http.server 8099        # in some directory with a big file
#   ADJUTANT_EXTERNAL_PORT=8099 ADJUTANT_EXTERNAL_PATH=/big.bin \
#     crystal spec spec/scratch/external_server_crash_spec.cr
module Adjutant
  describe "streamed fetch against an EXTERNAL server" do
    port_env = ENV["ADJUTANT_EXTERNAL_PORT"]?
    path = ENV["ADJUTANT_EXTERNAL_PATH"]? || "/big.bin"

    if port_env.nil?
      pending "raises mid-walk against a server in another process (set ADJUTANT_EXTERNAL_PORT)" { }
    else
      port = port_env.to_i
      url = "http://127.0.0.1:#{port}#{path}"

      # `local: true` because 127.0.0.1 is refused by §8.2 unless the
      # matching rule opts in — same as the in-process specs.
      grants = Legate::Grants.new(
        net_rules: [Legate::NetRule.new(
          host: "127.0.0.1", scheme: "http", ports: [port], local: true,
        )],
        net_methods: ["get"],
        limits: Legate::Limits.new,
      )

      # A control, so a crash below cannot be blamed on the external
      # server being unreachable or the grants being wrong. If this
      # fails, nothing after it means anything.
      it "can stream from the external server at all" do
        interp, _ = make_interp(grants: grants)
        result = interp.eval(<<-RUBY)
        total = 0
        Legate.fetch(#{url.inspect}, stream: true).body.each { |c| total = total + c.size }
        total
        RUBY
        result.as_int.should be > 0
        interp.broker.open_sources.size.should eq 0
      end

      # THE experiment. Byte-for-byte the crashing test, except for
      # where the server lives.
      #
      # Repeated because the in-process version is a race: which
      # example dies has moved between runs, so a single clean pass
      # would not be worth much.
      it "raises mid-walk against a server in another process" do
        5.times do
          interp, _ = make_interp(grants: grants)
          expect_raises(Exception) do
            interp.eval(<<-RUBY)
            Legate.fetch(#{url.inspect}, stream: true).body.each { |c| raise "boom" }
            RUBY
          end
          interp.broker.open_sources.size.should eq 0
        end
      end
    end
  end
end
