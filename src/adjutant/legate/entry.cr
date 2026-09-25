require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Entry` (LEGATE.md §5.3), built only by `Legate.list`.
    # Carries its stat data, so listing and then filtering by size
    # needs one pass. `size` and the object carry the join of `path`'s
    # label and `label`; `type` doesn't.
    module Entry
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Entry")
        path_sym = interp.symbols.intern("__path").value
        type_sym = interp.symbols.intern("__type").value
        size_sym = interp.symbols.intern("__size").value
        mtime_sym = interp.symbols.intern("__mtime").value

        Builtins.define(cls, interp, "path") { |args| args.first.as_robject.ivars[path_sym] }
        Builtins.define(cls, interp, "type") { |args| args.first.as_robject.ivars[type_sym] }
        Builtins.define(cls, interp, "size") { |args| args.first.as_robject.ivars[size_sym] }
        Builtins.define(cls, interp, "mtime") { |args| args.first.as_robject.ivars[mtime_sym] }
      end

      # `path` is a Legate::Path, `type` one of `:file`, `:dir`,
      # `:symlink` or `:other`, `mtime` a Time.
      def self.build(interp : Interpreter, rclass : RubyClass, path : Value, type : Symbol,
                     size : Int64, mtime : Value, label : RiskFlowLabel? = nil) : Value
        joined = RiskFlowLabel.join(path.label, label)
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__path").value] = path
        obj.ivars[interp.symbols.intern("__type").value] = Value.symbol(interp.symbols.intern(type.to_s))
        obj.ivars[interp.symbols.intern("__size").value] = Value.int(size, joined)
        obj.ivars[interp.symbols.intern("__mtime").value] = mtime
        Value.robject(obj, joined)
      end
    end
  end
end
