require "../spec_helper"

module Adjutant
  # A stand-in for any native error that knows more than it can say in
  # a sentence — an HTTP status here, an exit code or a byte count
  # elsewhere. Subclasses StandardError so an ordinary script `rescue`
  # catches it, and defines READER METHODS over the ivars the raising
  # side attaches: attaching an attribute makes the value present, but
  # only a method makes it reachable from a script.
  private def self.bootstrap_http_error(interp : Interpreter) : RubyClass
    standard_error = interp.get_global("StandardError").as_rclass
    cls = RubyClass.new("HttpError", standard_error)

    status_sym = interp.symbols.intern("status").value
    cls.define_native_method(status_sym, RiskProfile.none) do |args|
      args.first.as_robject.ivars[status_sym]? || Value.nil_value
    end

    location_sym = interp.symbols.intern("location").value
    cls.define_native_method(location_sym, RiskProfile.none) do |args|
      args.first.as_robject.ivars[location_sym]? || Value.nil_value
    end

    interp.define_global_class(cls)
  end

  # Registers `Probe.fail(status, location)`, which raises HttpError
  # with those two values attached — the shape every real caller of
  # this capability has.
  private def self.bootstrap_probe(interp : Interpreter, error_class : RubyClass) : RubyClass
    cls = RubyClass.new("Probe")
    fail_sym = interp.symbols.intern("fail").value
    cls.define_native_singleton_method(fail_sym, RiskProfile.none) do |args, _blk, ncc|
      status = args[1]? || Value.nil_value
      location = args[2]? || Value.nil_value
      ncc.raise_error_class(
        "probe failed with #{status.as_int}",
        error_class,
        {"status" => status, "location" => location},
      )
    end
    interp.define_global_class(cls)
  end

  private def self.interp_with_probe : Interpreter
    interp, _ = make_interp
    error_class = bootstrap_http_error(interp)
    bootstrap_probe(interp, error_class)
    interp
  end

  describe "native error attributes" do
    it "makes an attached attribute readable from a script" do
      interp = interp_with_probe
      eval = interp.eval(<<-RUBY)
      code = nil
      begin
        Probe.fail(307, "https://example.com/moved")
      rescue HttpError => e
        code = e.status
      end
      code
      RUBY

      eval.as_int.should eq 307
    end

    # The whole point of the capability: branching on the value
    # WITHOUT parsing it back out of prose written for a human.
    it "lets a script branch on an attribute" do
      interp = interp_with_probe
      eval = interp.eval(<<-RUBY)
      result = nil
      begin
        Probe.fail(303, "https://example.com/receipt")
      rescue HttpError => e
        if e.status == 303
          result = "follow"
        else
          result = "hand back"
        end
      end
      result
      RUBY

      eval.as_string.should eq "follow"
    end

    it "carries more than one attribute" do
      interp = interp_with_probe
      eval = interp.eval(<<-RUBY)
      target = nil
      begin
        Probe.fail(301, "https://example.com/new")
      rescue HttpError => e
        target = e.location
      end
      target
      RUBY

      eval.as_string.should eq "https://example.com/new"
    end

    # Attributes are additive — `message` must survive untouched, since
    # every existing rescue in every existing script reads it.
    it "leaves message intact alongside the attributes" do
      interp = interp_with_probe
      eval = interp.eval(<<-RUBY)
      text = nil
      begin
        Probe.fail(500, "https://example.com/x")
      rescue HttpError => e
        text = e.message
      end
      text
      RUBY

      eval.as_string.should eq "probe failed with 500"
    end

    # The parameter is optional, so every existing caller — every
    # Legate verb, every builtin — keeps working unchanged and its
    # errors carry nothing extra.
    it "attaches nothing when no attributes are given" do
      interp, _ = make_interp
      standard_error = interp.get_global("StandardError").as_rclass
      plain = RubyClass.new("PlainError", standard_error)
      interp.define_global_class(plain)

      probe = RubyClass.new("Bare")
      fail_sym = interp.symbols.intern("fail").value
      probe.define_native_singleton_method(fail_sym, RiskProfile.none) do |_args, _blk, ncc|
        ncc.raise_error_class("nothing attached", plain)
      end
      interp.define_global_class(probe)

      eval = interp.eval(<<-RUBY)
      text = nil
      begin
        Bare.fail
      rescue PlainError => e
        text = e.message
      end
      text
      RUBY

      eval.as_string.should eq "nothing attached"
    end
  end
end
