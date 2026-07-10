require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the four literal/singleton-value builtin classes: NilClass
  # (the class of `nil`), TrueClass and FalseClass (real Ruby has two
  # distinct singleton classes here, not one shared Boolean), and
  # Symbol (`:foo`). All pure (RiskProfile.none).
  #
  # Deliberately small method surface: `==` for all four, and `nil?`
  # for NilClass specifically, are already correct without any native
  # method here — `==` compiles to Op::Eq (see VM#values_equal?, which
  # already has real cases for Bool/Nil/Sym), and `nil?` is a universal
  # exec_builtin fallback that checks Value#null? directly regardless
  # of receiver class. `&`/`|`/`^` on booleans, and `NilClass#to_a`,
  # are deferred — the former isn't needed by anything yet, the latter
  # needs Array to exist first (a later phase).
  def self.bootstrap_nil_class(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("NilClass")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.to_s)
    end

    cls
  end

  def self.bootstrap_true_class(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("TrueClass")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.to_s)
    end

    cls
  end

  def self.bootstrap_false_class(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("FalseClass")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.to_s)
    end

    cls
  end

  def self.bootstrap_symbol(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Symbol")

    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.as_sym.name)
    end

    define(cls, interp, "to_sym") do |args|
      args.first
    end

    cls
  end
end
