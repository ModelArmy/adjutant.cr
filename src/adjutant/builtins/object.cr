require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Adds Object's default `to_s` and `inspect`, which every class
  # inherits, to the Object class the interpreter has already built.
  # `inspect` is `#<Foo @x=1, @y="hi">`: Ruby's format without the
  # memory address, each ivar rendered by its own `inspect`.
  def self.bootstrap_object_methods(interp : Adjutant::Interpreter, cls : Adjutant::RubyClass) : Nil
    define(cls, interp, "to_s") do |args|
      Adjutant::Value.string(args.first.to_s)
    end

    # A receiver that isn't an object (a builtin value whose class has
    # no `inspect` of its own) renders with `Value#inspect`.
    define(cls, interp, "inspect") do |args, _blk, ncc|
      recv = args.first
      obj = recv.as_robject?
      if obj.nil?
        Adjutant::Value.string(recv.inspect)
      elsif obj.ivars.empty?
        Adjutant::Value.string(recv.to_s)
      else
        pairs = obj.ivars.map do |sym_id, ivar_value|
          name = interp.symbols.name_for(sym_id) || "?"
          inspected = ncc.call_method(ivar_value, "inspect", [] of Adjutant::Value)
          "#{name}=#{inspected.as_string}"
        end
        Adjutant::Value.string("#<#{obj.rclass.name} #{pairs.join(", ")}>")
      end
    end
  end
end
