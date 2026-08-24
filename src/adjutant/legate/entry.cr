require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Entry` — LEGATE.md §5.3. Broker-manufactured only — see
    # Stat's own comment for why (no public constructor; plain
    # `RubyObject` + `__`-prefixed ivars, same as every value type but
    # `Path`). Carries its own stat data so `Legate.list` followed by
    # a size filter costs one syscall pass, not two (the spec's own
    # stated reason for this type existing separately from a bare
    # `Legate::Path`).
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

      # `path` is a real `Legate::Path` Value; `type` one of `:file`/
      # `:dir`/`:symlink`/`:other` (a real Sym, matching Stat.build's
      # own convention); `mtime` a real `Time` Value.
      def self.build(interp : Interpreter, rclass : RubyClass, path : Value, type : Symbol,
                     size : Int64, mtime : Value) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__path").value] = path
        obj.ivars[interp.symbols.intern("__type").value] = Value.symbol(interp.symbols.intern(type.to_s))
        obj.ivars[interp.symbols.intern("__size").value] = Value.int(size)
        obj.ivars[interp.symbols.intern("__mtime").value] = mtime
        Value.robject(obj)
      end
    end
  end
end
