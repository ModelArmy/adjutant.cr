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
  # directly, unwrapped — see UNSUPPORTED.md's U001, on block
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
    filename_sym = interp.symbols.intern("__filename").value
    line_sym = interp.symbols.intern("__line").value

    # `.(...)` sugar is not implemented (no parser support for it
    # today) — only explicit `.call(...)`. Real Ruby's `.(...)` is
    # just sugar for `.call(...)`; omitting the sugar keeps Adjutant a
    # proper subset without losing any real capability.
    define(cls, interp, "call") do |args, _blk, ncc|
      obj = args.first.as_robject
      # invoke_proc pulls both the wrapped ScriptProc (__sproc) and
      # the lambda's real closure snapshot (obj.outer_locals, taken by
      # Op::MakeProc at the lambda's true creation site) off `obj`
      # itself — see VM#invoke_proc's own comment. This replaced a
      # manual `ncc.invoke(sproc, args, outer_locals: obj.outer_locals)`
      # call after the 2026-07-20 closure-capture fix: that shape let
      # any future native method accepting a Proc arg forget to pass
      # outer_locals and silently reintroduce the same bug at a new
      # call site — invoke_proc removes that possibility structurally.
      ncc.invoke_proc(obj, args[1..])
    end

    # `lambda?` always true here: only Lambda-node output ever becomes
    # a Proc instance (see scope boundary above), so there is currently
    # no non-lambda Proc for this to distinguish from. Included now
    # rather than left out, since real Ruby's Proc always has it and a
    # future block-capture piece (if ever added — see UNSUPPORTED.md,
    # U001) would set this to false on that path, not need to add the
    # method itself.
    define(cls, interp, "lambda?") do |_args|
      Adjutant::Value.bool(true)
    end

    # Real Ruby: `Proc#to_s`/`#inspect` render identically —
    # `#<Proc:0x... file:line (lambda)>` for a lambda, no `(lambda)`
    # suffix for an ordinary (non-lambda) Proc — as I recall it, not
    # independently confirmed here; worth a real `irb` check,
    # including the exact separator real Ruby uses between the
    # (here, omitted) address and `file:line` (I believe it may be
    # `@`, not a plain space — `#<Proc:0x...@file:line (lambda)>` —
    # this implementation just uses a space after `Proc`, since
    # there's no address to separate FROM here). `(lambda)` is
    # UNCONDITIONAL here, not a check against `lambda?` — same
    # reasoning as `lambda?` itself just above: only Lambda-node
    # output ever becomes a Proc instance at all, so there's no
    # non-lambda case to distinguish from today. The memory address
    # (`0x...`) is deliberately OMITTED — no debugging value here (not
    # stable across runs, nothing script-side can correlate it
    # against, Adjutant doesn't expose real addresses to begin with),
    # the same reasoning `Object#inspect`'s own default already
    # applies (builtins/object.cr). `file:line` IS included — real
    # debugging value (which literal lambda, in a script with several)
    # that `__filename`/`__line` (vm.cr's `make_lambda_object`, set at
    # the lambda's CREATION site, not wherever `.call` later happens
    # to run from) make available for free.
    #
    # Before this, Proc had NO to_s/inspect at all, meaning it fell
    # through to `Object`'s own default `#inspect` — which lists
    # ivars, and Proc's own internal representation ivar is literally
    # named `__sproc`, so the OLD behavior LEAKED that implementation
    # detail into user-visible output (`#<Proc __sproc=#<Proc> ...>`),
    # not just an incomplete rendering.
    define(cls, interp, "to_s") do |args|
      obj = args.first.as_robject
      filename = obj.ivars[filename_sym].as_string
      line = obj.ivars[line_sym].as_int
      Adjutant::Value.string("#<Proc #{filename}:#{line} (lambda)>")
    end

    define(cls, interp, "inspect") do |args, _blk, ncc|
      ncc.call_method(args.first, "to_s", [] of Adjutant::Value)
    end

    cls
  end
end
