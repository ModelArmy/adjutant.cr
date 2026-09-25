require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Match` (LEGATE.md §5.4), built only by `Legate.grep`.
    # `text`, `before`, `after` and the object carry the join of
    # `path`'s label and `label`; `line_no` doesn't.
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

      # `before` and `after` are empty unless `context:` was given
      # (§5.4).
      def self.build(interp : Interpreter, rclass : RubyClass, path : Value, line_no : Int64,
                     text : String, before : Array(String) = [] of String,
                     after : Array(String) = [] of String, label : RiskFlowLabel? = nil) : Value
        joined = RiskFlowLabel.join(path.label, label)
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__path").value] = path
        obj.ivars[interp.symbols.intern("__line_no").value] = Value.int(line_no)
        obj.ivars[interp.symbols.intern("__text").value] = Value.string(text, joined)
        obj.ivars[interp.symbols.intern("__before").value] = Value.new(LabeledArray.new(before.map { |line| Value.string(line, joined) }, joined), joined)
        obj.ivars[interp.symbols.intern("__after").value] = Value.new(LabeledArray.new(after.map { |line| Value.string(line, joined) }, joined), joined)
        Value.robject(obj, joined)
      end
    end
  end
end
