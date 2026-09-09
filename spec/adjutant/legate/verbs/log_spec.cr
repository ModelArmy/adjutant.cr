require "../../../spec_helper"
require "log"

module Adjutant
  describe "Legate.log" do
    it "writes the message and fields through the embedder-supplied Log" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      interp.eval(%(Legate.log("hello", {status: "ok", count: 3})))

      backend.entries.size.should eq 1
      entry = backend.entries.first
      entry.message.should eq "hello"
      entry.severity.should eq ::Log::Severity::Info
      entry.source.should eq "adjutant.spec.log"
    end

    it "accepts String-keyed fields exactly as well as Symbol-keyed ones" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      interp.eval(%(Legate.log("hello", {"status" => "ok"})))

      backend.entries.size.should eq 1
    end

    it "defaults fields to empty when the second argument is omitted" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      interp.eval(%(Legate.log("no fields here")))

      backend.entries.size.should eq 1
      backend.entries.first.message.should eq "no fields here"
    end

    it "returns nil" do
      interp, _ = make_interp
      eval = interp.eval(%(Legate.log("x").nil?.to_s))
      eval.as_string.should eq "true"
    end

    it "needs no grant at all — works under Grants.deny_all, same as every ambient verb" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("ambient, no grant needed")
        "no error"
      rescue
        "errored"
      end
      RUBY
      eval.as_string.should eq "no error"
    end

    it "raises ArgumentError (R041) when message is missing" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log
        "no error"
      rescue ArgumentError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when message isn't a String" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log(42)
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when fields isn't a Hash" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("hello", "not a hash")
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "raises TypeError (R039) when a field value doesn't coerce (e.g. a lambda)" do
      interp, _ = make_interp(grants: Legate::Grants.deny_all)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("hello", {bad: lambda { 1 }})
        "no error"
      rescue TypeError
        "caught"
      end
      RUBY
      eval.as_string.should eq "caught"
    end

    it "accepts a nested Array/Hash of loggable values" do
      backend = ::Log::MemoryBackend.new
      builder = ::Log::Builder.new
      builder.bind("*", ::Log::Severity::Trace, backend)
      log = builder.for("adjutant.spec.log")

      interp, _ = make_interp(log: log)
      eval = interp.eval(<<-RUBY)
      begin
        Legate.log("hello", {tags: ["a", "b"], nested: {ok: true}})
        "no error"
      rescue
        "errored"
      end
      RUBY
      eval.as_string.should eq "no error"
      backend.entries.size.should eq 1
    end
  end
end
