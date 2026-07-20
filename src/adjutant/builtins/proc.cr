require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

module Adjutant::Builtins
  # Builds the `Proc` RubyClass and registers its native methods.
  #
  # Piece C (see SCOPE.md): a `Lambda` node (`->(){}`) compiles
  # (compile_lambda, Op::MakeProc with a=1 — see vm.cr) to a
  # real RubyObject of class Proc, not a bare Value.proc(sproc) as
  # before. This gives lambdas .class/is_a?/.call, matching real Ruby.
  # Only `->(){}` — Adjutant has no Kernel `lambda { }` function; that
  # spelling isn't valid Adjutant at all (parses as an ordinary bare
  # call named `lambda`, fails at runtime as an undefined method).
  #
  # The wrapped ScriptProc is stored as-is in the single ivar __sproc,
  # reusing Value's existing `proc` variant rather than inventing a new
  # Value representation — RubyObject#ivars is Hash(Int32, Value), and
  # Value.proc(sproc) already exists as a constructible variant (it's
  # exactly what def bodies and call-site block literals still use
  # directly, unwrapped — see SCOPE.md's Won't Fix entry on block
  # capture). Proc is just the first case where that variant also gets
  # a RubyObject shell around it.
  #
  # Scope boundary (SCOPE.md, confirmed 2026-07-18): only Lambda-node
  # output goes through this wrapping. Call-site block literals
  # (`{ }`/`do...end`, consumed via `yield`) and `def` bodies are
  # unaffected — they keep using bare Value.proc(sproc), never see this
  # class. No &blk-param capture exists or is added here.
  #
  # No bare `name(...)`-without-`.call` support is added (a local
  # holding a Proc is not directly callable) — real Ruby doesn't
  # support that either; `dbl(3)` resolves as a bare method call, never
  # as invoking a local. This was corrected in SCOPE.md 2026-07-18
  # after being mistakenly scoped in as a goal. `.call` alone is
  # correct and sufficient; it works via the VM's existing
  # `recv.robject?` receiver-dispatch path (vm.cr dispatch_call) with
  # no changes needed there — same as any other builtin instance
  # method.
  def self.bootstrap_proc(interp : Adjutant::Interpreter) : Adjutant::RubyClass
    cls = Adjutant::RubyClass.new("Proc")

    sproc_sym = interp.symbols.intern("__sproc").value

    # `.(...)` sugar is not implemented (no parser support for it
    # today) — only explicit `.call(...)`. Real Ruby's `.(...)` is
    # just sugar for `.call(...)`; omitting the sugar keeps Adjutant a
    # proper subset without losing any real capability.
    define(cls, interp, "call") do |args, _blk, ncc|
      obj = args.first.as_robject
      sproc = obj.ivars[sproc_sym].as_proc
      # obj.outer_locals is the snapshot taken when this specific
      # ->(){} literal was evaluated (Op::MakeProc, vm.cr) — the
      # lambda's true lexical parent scope, regardless of which frame
      # .call happens to run in now. Without passing it explicitly,
      # VM#invoke falls back to the CALLING frame's locals, which is
      # only right when .call happens to run in the same frame that
      # defined the lambda — see the 2026-07-20 closure-capture bug
      # (research/IFC_DESIGN.md) this fixes.
      ncc.invoke(sproc, args[1..], outer_locals: obj.outer_locals)
    end

    # `lambda?` always true here: only Lambda-node output ever becomes
    # a Proc instance (see scope boundary above), so there is currently
    # no non-lambda Proc for this to distinguish from. Included now
    # rather than left out, since real Ruby's Proc always has it and a
    # future block-capture piece (if ever added — see SCOPE.md Won't
    # Fix) would set this to false on that path, not need to add the
    # method itself.
    define(cls, interp, "lambda?") do |_args|
      Adjutant::Value.bool(true)
    end

    cls
  end
end
