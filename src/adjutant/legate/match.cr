require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Match` — LEGATE.md §5.4. Broker-manufactured only —
    # see Stat's own comment for why (no public constructor; plain
    # `RubyObject` + `__`-prefixed ivars).
    module Match
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Match")
        path_sym = interp.symbols.intern("__path").value
        line_no_sym = interp.symbols.intern("__line_no").value
        text_sym = interp.symbols.intern("__text").value
        before_sym = interp.symbols.intern("__before").value
        after_sym = interp.symbols.intern("__after").value

        Builtins.define(cls, interp, "path") { |args| args.first.as_robject.ivars[path_sym] }
        Builtins.define(cls, interp, "line_no") { |args| args.first.as_robject.ivars[line_no_sym] }
        Builtins.define(cls, interp, "text") { |args| args.first.as_robject.ivars[text_sym] }
        Builtins.define(cls, interp, "before") { |args| args.first.as_robject.ivars[before_sym] }
        Builtins.define(cls, interp, "after") { |args| args.first.as_robject.ivars[after_sym] }
      end

      # `before`/`after` default to an empty Array — LEGATE.md §5.4:
      # "empty unless context: was given".
      def self.build(interp : Interpreter, rclass : RubyClass, path : Value, line_no : Int64,
                     text : String, before : Array(String) = [] of String,
                     after : Array(String) = [] of String) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__path").value] = path
        obj.ivars[interp.symbols.intern("__line_no").value] = Value.int(line_no)
        obj.ivars[interp.symbols.intern("__text").value] = Value.string(text)
        obj.ivars[interp.symbols.intern("__before").value] = Value.new(LabeledArray.new(before.map { |line| Value.string(line) }), nil)
        obj.ivars[interp.symbols.intern("__after").value] = Value.new(LabeledArray.new(after.map { |line| Value.string(line) }), nil)
        Value.robject(obj)
      end
    end
  end
end
