require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Exit` — LEGATE.md §5.6. Broker-manufactured only — see
    # Stat's own comment for why (no public constructor; plain
    # `RubyObject` + `__`-prefixed ivars).
    #
    # IFC: `out`/`err` (actual subprocess output — arguably the
    # highest-stakes data any Legate value type carries, given how
    # much a subprocess can see) and the outer object are labeled with
    # an explicit `label`. Unlike `Entry`/`Match`, there's
    # no natural "input Value" here to derive a default from (a
    # command's OUTPUT isn't naturally the same taint as whatever
    # tainted argv produced it — real Ruby has no automatic notion of
    # "running a tainted command taints its output" either) — the
    # broker supplies `label` directly, however it decides to compute
    # it. `code`/`truncated`/`duration` stay unlabeled — metadata,
    # same rule as every other Legate value type's own comment.
    module Exit
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Exit")
        code_sym = interp.symbols.intern("__code").value
        out_sym = interp.symbols.intern("__out").value
        err_sym = interp.symbols.intern("__err").value
        truncated_sym = interp.symbols.intern("__truncated").value
        duration_sym = interp.symbols.intern("__duration").value

        Builtins.define(cls, interp, "code") { |args| args.first.as_robject.ivars[code_sym] }
        Builtins.define(cls, interp, "ok?") { |args| Value.bool(args.first.as_robject.ivars[code_sym].as_int.zero?) }
        Builtins.define(cls, interp, "out") { |args| args.first.as_robject.ivars[out_sym] }
        Builtins.define(cls, interp, "err") { |args| args.first.as_robject.ivars[err_sym] }
        Builtins.define(cls, interp, "truncated?") { |args| args.first.as_robject.ivars[truncated_sym] }
        Builtins.define(cls, interp, "duration") { |args| args.first.as_robject.ivars[duration_sym] }
      end

      def self.build(interp : Interpreter, rclass : RubyClass, code : Int32, out_text : String,
                     err : String, truncated : Bool, duration : Float64, label : RiskFlowLabel? = nil) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__code").value] = Value.int(code)
        obj.ivars[interp.symbols.intern("__out").value] = Value.string(out_text, label)
        obj.ivars[interp.symbols.intern("__err").value] = Value.string(err, label)
        obj.ivars[interp.symbols.intern("__truncated").value] = Value.bool(truncated)
        obj.ivars[interp.symbols.intern("__duration").value] = Value.float(duration)
        Value.robject(obj, label)
      end
    end
  end
end
