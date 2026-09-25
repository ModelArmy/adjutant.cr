require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds NilClass, TrueClass, FalseClass and Symbol. `==` is an
  # opcode and `nil?` a VM builtin, so neither is registered here.
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
