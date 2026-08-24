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
    module Exit
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Exit")
        code_sym = interp.symbols.intern("__code").value
        out_sym = interp.symbols.intern("__out").value
        err_sym = interp.symbols.intern("__err").value
        truncated_sym = interp.symbols.intern("__truncated").value
        duration_sym = interp.symbols.intern("__duration").value
        non_zero_exit = Helpers.fetch(legate, interp, "NonZeroExit")

        Builtins.define(cls, interp, "code") { |args| args.first.as_robject.ivars[code_sym] }
        Builtins.define(cls, interp, "ok?") { |args| Value.bool(args.first.as_robject.ivars[code_sym].as_int.zero?) }
        Builtins.define(cls, interp, "out") { |args| args.first.as_robject.ivars[out_sym] }
        Builtins.define(cls, interp, "err") { |args| args.first.as_robject.ivars[err_sym] }
        Builtins.define(cls, interp, "truncated?") { |args| args.first.as_robject.ivars[truncated_sym] }
        Builtins.define(cls, interp, "duration") { |args| args.first.as_robject.ivars[duration_sym] }

        # Raises Legate::NonZeroExit unless ok?, else returns self —
        # same "common case wants this fatal" reasoning as
        # Legate::Response#raise! (LEGATE.md §5.5/§5.6), and the exact
        # gap that surfaced the spec fix from Legate::Transport (a
        # network-scoped class — wrong domain entirely for a failed
        # subprocess) to a dedicated Legate::NonZeroExit class.
        Builtins.define(cls, interp, "raise!") do |args, _blk, ncc|
          code = args.first.as_robject.ivars[code_sym].as_int
          unless code.zero?
            ncc.raise_error_class("Legate::Exit#raise! — exit code #{code}", non_zero_exit)
          end
          args.first
        end
      end

      def self.build(interp : Interpreter, rclass : RubyClass, code : Int32, out_text : String,
                     err : String, truncated : Bool, duration : Float64) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__code").value] = Value.int(code)
        obj.ivars[interp.symbols.intern("__out").value] = Value.string(out_text)
        obj.ivars[interp.symbols.intern("__err").value] = Value.string(err)
        obj.ivars[interp.symbols.intern("__truncated").value] = Value.bool(truncated)
        obj.ivars[interp.symbols.intern("__duration").value] = Value.float(duration)
        Value.robject(obj)
      end
    end
  end
end
