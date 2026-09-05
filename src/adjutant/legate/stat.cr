require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Stat` — LEGATE.md §5.2. Broker-manufactured only (no
    # public constructor here — see Path's own comment on why every
    # Legate value type except Path is plain `RubyObject` + `__`-
    # prefixed ivars, sidestepping the dup/clone-loses-typed-state bug
    # SCOPE.md's Must Fix tracks). `.build` below is the CRYSTAL-level
    # constructor the future broker/verb code calls directly; nothing
    # here exposes a script-visible `.new` at all, matching every
    # other value type's "returned by verbs, never built by scripts"
    # shape.
    #
    # IFC: `label` (what the broker will pass — typically derived from
    # the queried Path's own taint) seeds `__size` (actual DATA about
    # the file) and the outer object; `__type`/`__mode` stay unlabeled
    # (a classification symbol and a permission bitmask are METADATA,
    # not extracted data — same rule `Legate::Path`'s own top comment
    # documents, following `regexp.cr`'s `__options` precedent).
    # `mtime` is passed through as-given — whatever label the CALLER
    # already put on that `Time` Value is this method's problem to
    # preserve, not recompute.
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

      # `type` is one of `:file`, `:dir`, `:symlink`, `:other` — a
      # real Sym Value, not a bare String, matching the spec's own
      # `:file | :dir | :symlink | :other` notation. `mtime` is a
      # real `Time` Value (builtins/time.cr) — the whole reason that
      # type had to exist before this file could.
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
