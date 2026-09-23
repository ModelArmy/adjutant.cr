require "wiretap"
require "../adjutant"

module Testing
  # Records and replays HTTP for script specs, via the `wiretap` shard.
  # Test runner only: an embedder's interpreter never registers it, since
  # it would carry network traffic that Legate's grants never see.
  #
  #   require "wiretap"
  #   response = wiretap("status_ok") { Legate.fetch("https://httpbin.org/json") }
  #
  # `wiretap(name) { ... }` runs the block with every HTTP request replayed
  # from `transcripts/<name>.json` beside the script, and returns the
  # block's value. A request with no matching interaction fails the block.
  # With `WIRETAP_RECORD` set in the environment, a missing transcript is
  # recorded from the real server instead; commit it afterwards.
  #
  # `name` is letters, digits, `_` and `-` only, so a transcript can never
  # land outside the script's own `transcripts/` folder.
  class WiretapModule < Adjutant::ScriptModule
    TRANSCRIPTS_DIR = "transcripts"
    NAME_PATTERN    = /\A[A-Za-z0-9_-]+\z/

    def name : String
      "wiretap"
    end

    def load(interp : Adjutant::Interpreter) : Nil
      interp.define_native("wiretap") do |args, blk, ncc|
        name = args.first?
        unless name && name.string? && NAME_PATTERN.matches?(name.as_string)
          raise Adjutant::RuntimeError.new(
            "wiretap needs a transcript name of letters, digits, `_` and `-`", ncc.filename, ncc.line)
        end
        raise Adjutant::RuntimeError.new("wiretap needs a block", ncc.filename, ncc.line) unless blk

        result = Adjutant::Value.nil_value
        Wiretap.intercept(self.class.transcript_name(ncc.filename, name.as_string), mode: self.class.record_mode) do
          result = ncc.invoke(blk, [] of Adjutant::Value)
        end
        result
      end
    end

    # `:once` when `WIRETAP_RECORD` is set, so a missing transcript is
    # recorded; otherwise `:none`, so it fails loudly rather than quietly
    # reaching the network.
    def self.record_mode : Symbol
      ENV["WIRETAP_RECORD"]? ? :once : :none
    end

    # The transcript's name as Wiretap resolves it: relative to the
    # current directory, which `Runner` makes Wiretap's `transcript_dir`.
    def self.transcript_name(script_path : String, name : String) : String
      dir = Path[File.expand_path(File.dirname(script_path))].relative_to(Dir.current)
      (dir / TRANSCRIPTS_DIR / name).to_posix.to_s
    end

    # Configures Wiretap and `Legate.fetch`'s resolver for a whole run.
    # Call once, before any script starts.
    #
    # `Legate.fetch` resolves and checks a host's address before Wiretap
    # answers, so even a replay needs one. Inside a `wiretap` block the
    # resolver resolves for real when DNS answers, so recording pins to
    # the genuine host, and otherwise returns a fixed public placeholder
    # that replay never connects to. Outside a block, where nothing would
    # stop a real connection, it resolves as usual and fails offline.
    def self.setup : Nil
      Wiretap.configure(&.transcript_dir=("."))
      Adjutant::Legate::Verbs::Fetch.resolver = ->(host : String, port : Int32) {
        begin
          Socket::Addrinfo.tcp(host, port).map(&.ip_address)
        rescue e : Socket::Error
          raise e unless Wiretap.active_transcript
          [Socket::IPAddress.new("93.184.216.34", port)]
        end
      }
    end
  end
end
