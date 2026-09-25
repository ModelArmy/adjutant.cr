require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Stat` (LEGATE.md §5.2), built only by verbs through
    # `build`; no script-visible `new`. `label` goes on `size` and the
    # object; `type` and `mode` are metadata and don't; `mtime` keeps
    # whatever label it has.
    module Stat
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Stat")
        type_sym = interp.symbols.intern("__type").value
        size_sym = interp.symbols.intern("__size").value
        mtime_sym = interp.symbols.intern("__mtime").value
        mode_sym = interp.symbols.intern("__mode").value

        Builtins.define(cls, interp, "type") { |args| args.first.as_robject.ivars[type_sym] }
        Builtins.define(cls, interp, "size") { |args| args.first.as_robject.ivars[size_sym] }
        Builtins.define(cls, interp, "mtime") { |args| args.first.as_robject.ivars[mtime_sym] }
        Builtins.define(cls, interp, "mode") { |args| args.first.as_robject.ivars[mode_sym] }
        Builtins.define(cls, interp, "file?") { |args| Value.bool(args.first.as_robject.ivars[type_sym].as_sym.name == "file") }
        Builtins.define(cls, interp, "dir?") { |args| Value.bool(args.first.as_robject.ivars[type_sym].as_sym.name == "dir") }
      end

      # `type` is one of `:file`, `:dir`, `:symlink` or `:other`;
      # `mtime` is a Time.
      def self.build(interp : Interpreter, rclass : RubyClass, type : Symbol,
                     size : Int64, mtime : Value, mode : Int32, label : RiskFlowLabel? = nil) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__type").value] = Value.symbol(interp.symbols.intern(type.to_s))
        obj.ivars[interp.symbols.intern("__size").value] = Value.int(size, label)
        obj.ivars[interp.symbols.intern("__mtime").value] = mtime
        obj.ivars[interp.symbols.intern("__mode").value] = Value.int(mode)
        Value.robject(obj, label)
      end
    end
  end
end
