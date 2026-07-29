# Unsupported

Permanent record of what Adjutant deliberately does not support, and the
reasoning that closed the door on each. Unlike [SCOPE.md](./SCOPE.md) —
which tracks outstanding work, and whose items are expected to leave it —
nothing here is a work queue. An entry leaves this file only if the stated
reason no longer holds, which is a real design conversation, not a routine
edit.

Two standing principles shape every entry:

- **Adjutant should be, at worst, a proper subset of Ruby.** The only
  intended runtime difference from real Ruby is IFC support and its
  related exceptions. Declining a feature keeps that property; behaving
  *differently* from Ruby on a feature we claim to support breaks it.
  (Constants being assign-once is the one deliberate, load-bearing
  exception — see U003.)
- **An unsupported construct must fail immediately and clearly, naming
  the construct.** Never silently do nothing, never silently do something
  different from what was written, and never surface only as a confusing
  error much later when the script tries to use whatever the construct
  should have produced. Established 2026-07-27, after an audit found
  three declared-unsupported constructs doing exactly those things.

## How this file is organised

Section 1 lists constructs a **script author can actually write** — these
carry a `U`-series error code and are (or should be) rejected with a
message naming the construct. Section 2 lists **internal design
decisions** that no script can collide with; they have no error code and
produce no error, because there's nothing for a script to do wrong.

### About the `U` codes

`U` is the "deliberately unsupported" letter in Adjutant's diagnostic code
scheme, spanning every phase — some `U` diagnostics are raised by the
parser, some by the compiler, some by the VM. The letter encodes the *kind
of problem*, not which subsystem caught it, precisely so a code stays
stable when enforcement moves between phases (U004 moved from the VM to
the compiler mid-session; its identity shouldn't have changed with it).

Codes are allocated sequentially, never reused, and never renumbered. The
full registry across all letters lives in
[ERRORS.md](./ERRORS.md); `U` rows there link back here rather than
restating the reasoning, so each fact lives in exactly one place.

**Status note (2026-07-28):** the diagnostic system these codes key into
now exists, and **U001 and U004 are wired to it** — their errors carry a
structured `Diagnostic`, render with the offending source line and carets,
and draw their wording from the catalog rather than the raise site. The
remaining codes are allocated but not yet emitted: those errors still
carry a hand-written message and no code. Each entry records its current
enforcement state explicitly.

---

## 1. Unsupported language constructs

### U001 — `&blk` parameter capture

Block literals are never first-class `Proc` values. Only a `Lambda` node
(`->(){}` — Adjutant has no Kernel `lambda { }` function) becomes a real
`Proc` object. A `{ }`/`do...end` block passed to a call stays consumable
only via implicit `yield` inside that call: never bound to a named
parameter, never returned, never stored.

**Why:** decided 2026-07-18 alongside Piece C's design — narrowing the
subset rather than widening it, kept simple until something depends on it.
Real Ruby supports `def foo(&blk)`; Adjutant deliberately doesn't. This
property is load-bearing elsewhere: because a block can only ever run
synchronously via `yield`, block bodies don't increment `@def_depth` in
U004's check.

**Instead:** call the block with `yield`, or pass a lambda as an ordinary
parameter.

**Enforcement — active since 2026-07-27, compile time; migrated to a
structured `U001` diagnostic 2026-07-28.** Until then,
`def foo(&blk)` compiled fine and silently bound `blk` to `nil`; a script
only discovered the gap if it later tried to use `blk`, where `blk.call`
raised a generic "undefined method or variable: call" with no hint that
`&blk` was the real problem. Now rejected outright in `compile_def`
(`compiler.cr`). Verified via `compiler_spec.cr`'s "rejects &blk param
capture at compile time", plus a sibling regression check confirming
ordinary `yield` — a separate mechanism — is untouched by the guard.

Revisit as a new, separate scope item if a real script needs to hold and
defer-call a block.

### U002 — `Class.new` / `Module.new`

Dynamically defining a class or module at runtime, optionally with a block
as its body. `class Foo; end` — the literal, static form — is unaffected.

**Why:** an explicit cut from the Object/Class/Module design conversation
(2026-07-14 arc). That bootstrap exists only to make `Class`/`Module` real
`RubyClass`es so `.class`, `is_a?`, and `superclass` work correctly; they
were never meant to be instantiable from script. Supporting it would need
a native singleton `new` on `Class` capable of executing an arbitrary
block as a class body — materially harder than the rest of that bootstrap,
and not needed by anything driving the base-types work.

**Instead:** declare the class literally with `class Foo; end`.

**Enforcement — active since 2026-07-27, runtime.** Until then nothing
enforced this: `Class.new`/`Module.new` fell through to the generic
`construct_object` path and silently succeeded, producing a bare,
non-functional object with no name and no meaningful way to define methods
on it. `RubyClass` gained an `uninstantiable?` flag, set for
`Class`/`Module` specifically at bootstrap (see
`Interpreter#bootstrap_core_hierarchy`) and checked by `VM#construct`,
which now raises clearly. Verified via
`spec/scripts/language/class_module_new.rb`.

### U003 — Class/module reopening

Writing `class Foo; end` a second time to extend an existing class — real
Ruby's monkey-patching mechanism.

**Why:** Adjutant's constants, including class and module names, are
enforced assign-once, and reopening is exactly a second assignment to the
same constant. Supporting it would mean carving a special exemption from
that rule for classes and modules specifically, undermining the whole
reason the rule exists — constant-valued things (notably `Lambda`s used as
call arguments, Piece D) are statically resolvable precisely *because* a
constant can't quietly become something else later. Adjutant scripts are
LLM-generated and typically ephemeral or narrow in scope even when reused,
so the case for real monkey-patching is weak. Declining it also keeps
Adjutant a proper subset of Ruby, since it's a refusal rather than
divergent behaviour.

**Instead:** define the class once, with all its methods in that body. Note
the practical consequence for host integration: a native `new` (or any
`native_singleton_method`) must be registered on a class *before* script
code first defines it via `class Foo; end`, in that same definition.

**Enforcement — active since 2026-07-18, runtime, via the constant rule
rather than a dedicated check.** `Op::MakeClass` always allocates a fresh,
disconnected `RubyClass` for every `class Foo; end` it compiles, with no
reuse-if-already-exists check, so the reassignment guard in
`Op::SetConstant` is what converts a reopen into a loud error instead of
silent data loss.

**Confirmed concretely by the person, 2026-07-18:** before that guard
existed, reopening a *builtin* — `class String; def hello; "hello"; end;
end` — silently broke every native `String` method, `.upcase` included,
once the constant was reassigned to the fresh, disconnected class; the
native methods only ever lived on the original, now-unreachable one. This
is also what proved a same-shaped existing spec
(`singleton_methods_spec.cr`'s "a native singleton new still works
alongside script singleton methods on the same class") had always been
silently invalid — it exercised only `.new` plus one script method, narrow
enough never to surface the breakage. Removed outright rather than kept as
a documented gap, since the pattern it tested isn't coming back.

`Class.new`/`Module.new` (U002) is the same family of cut for the same
underlying reason.

### U004 — Defining a method inside another method's body

A `def` or `def self.foo` nested inside another method's or a lambda's
body — runtime-conditional method definition. A method definition may
appear only at the top level of a script, or directly inside a
`class`/`module` body.

**Why:** an object's callable surface should be knowable from its class
alone, without simulating execution. A method set that changes as a side
effect of calling some unrelated method destroys that property — the same
one U003 protects. Decided 2026-07-27, prompted by the person's own `irb`
trace of real Ruby's per-instance singleton-method semantics.

**Instead:** define the method at the top level or directly in the
class/module body. For behaviour that varies at runtime, use a lambda held
in a local or constant.

**This entry was corrected twice, and the sequence matters** — each step
corrected the step before it rather than merely narrowing it:

1. **Original framing:** `Op::DefSingleton` (`def self.foo` where `self`
   is a `RubyObject`, not a `RubyClass`) targets the receiver's *class*
   instead of the receiver itself. Believed to mean the method "leaks"
   onto every instance of that class.
2. **Corrected by running a script** (`singleton_instance_methods.rb`, now
   folded into `compiler_spec.cr`): that's wrong. `Op::DefSingleton`
   writes into the class's SINGLETON table, which only a
   `RubyClass`-receiver call (`A.foo`) ever consults — never an instance
   call (`a.foo`). So `class A; def test; def self.hello; end; end; end`
   doesn't leak to siblings at all; it creates a class-level method
   invisible to every instance, reachable only as `A.hello`. Fixed at the
   time with a runtime guard in `Op::DefSingleton` comparing the receiver
   against `main`.
3. **Generalised again the same session, from the person's own follow-up
   test:** that guard only covered the `def self.foo` shape. A plain `def
   nested` (no `self.`), nested identically, hits `Op::DefMethod` — never
   guarded — and writes straight into the class's ORDINARY instance method
   table. Confirmed with `class X5; def test; def nested; end; end; end`:
   calling `x.test` made `nested` callable on `x`, on a pre-existing
   instance `y`, and on instances constructed afterwards. A real leak to
   every instance — genuinely, this time, and reached by a completely
   different path from the one step 1 guessed at.

   This proved the real boundary was never "singleton vs instance method"
   or "which opcode" at all. It's whether a `def` executes exactly once,
   synchronously, as part of establishing the class — top level, or
   directly inside a class/module body — versus later and conditionally,
   as part of calling some other already-defined method. Both
   `Op::DefMethod` and `Op::DefSingleton` need the same answer, not two
   different mechanisms.

**Enforcement — active since 2026-07-27, compile time, final version;
migrated to a structured `U004` diagnostic 2026-07-28.**
Moved out of `vm.cr` entirely into `Compiler#compile_def`: a `@def_depth`
counter, incremented for `def` and lambda bodies (genuinely
deferred/callable-later contexts), propagated unchanged through block
bodies (which can only run synchronously via `yield` — see U001), and
threaded through `compile_proc`, since a nested proc body compiles via a
brand-new `Compiler` instance that wouldn't otherwise see it. Any
`def`/`def self.foo` compiled while `@def_depth > 0` is rejected
regardless of receiver — strictly earlier and more complete than the
runtime guard it replaced, which it subsumes by construction, since `self`
can only be a non-`main` `RubyObject` inside another method's body to
begin with. Ordinary top-level `def`, top-level `def self.foo`, and `def`
directly inside a `class`/`module` body are all unaffected. Verified via
`compiler_spec.cr`'s nested-def specs, covering the `def self.foo` shape,
the plain-`def` shape, a def-inside-a-lambda shape, and regression checks
for both unaffected cases.

**Known uncovered case, flagged and not yet decided:** because block
bodies don't increment `@def_depth`, a top-level `[1,2,3].each { def foo;
end }` — not nested in any `def` — still compiles today. Same class of
problem in principle, just not the case anyone actually hit.

### U005 — Dynamic dispatch by computed method name

`send`, `public_send`, `method_missing`, and `define_method` with a
runtime-computed name.

**Why:** `Call#method` in the AST is always a literal `String`, and keeping
it that way is what makes every call site statically resolvable to a
`NativeCallable`/`ScriptProc` for risk aggregation. This is not a scoping
cut that effort could reverse — it's a static-analysis hazard. If it ever
changed, `RiskUnresolved` is the fallback, but the goal is for that to
stay rare.

**Instead:** call the method directly by name, or branch explicitly.

**Enforcement — none specific, as of 2026-07-28.** These names are simply
undefined, so a script using one gets a generic undefined-method error that
doesn't explain the construct is deliberately excluded. This is the same
failure shape the 2026-07-27 audit removed from U001–U004, and is a
candidate for the same treatment. Unverified — flagged 2026-07-28, not
empirically confirmed.

### U006 — `eval` / `instance_eval` on runtime strings

**Why:** same reasoning as U005 — a script that can construct and run
arbitrary code at runtime has no static risk profile at all.

**Instead:** nothing; this is permanently excluded by the risk model.

**Enforcement — none specific, as of 2026-07-28.** See U005.

### U007 — Reflection exposing native/Crystal internals

Arbitrary FFI, `ObjectSpace`-style introspection, and similar.

**Why:** not needed by anything on the roadmap, and it would let a script
route around the effect boundary (`EffectHandler`/`ModuleRegistry`)
entirely.

**Instead:** register what the script legitimately needs as a native module
with a declared risk profile.

**Enforcement — none specific, as of 2026-07-28.** See U005.

---

## 2. Design decisions with no script-visible surface

These are closed decisions about Adjutant's own API shape. No script can
collide with them, so they carry no error code and raise nothing.

- **A per-parameter declarative provenance schema for
  `declare_sensitivity`** — declaring provenance at `define_native`
  registration time instead of the current call-site-driven API. Rejected
  during the original IFC design arc: Ruby's dynamic arity (variadic
  functions, optional args, role-depends-on-other-args patterns) has no
  fixed positional contract a schema could describe reliably.
- **Adjutant should never generate end-user-facing prompt text itself**,
  for i18n reasons. The agent-facing API for consuming a
  `RiskFlowDecisionRequest` stays documentation and samples, not new core
  API surface. Decided during the original IFC design arc.
- **Wildcard-counting or array-order-as-priority for `RiskFlowPolicy`
  pattern specificity.** Both considered and rejected during the original
  IFC design arc — hostnames get more specific reading left, paths reading
  right, and no single syntax-driven rule generalises across both.
  `priority` is an explicit field instead, with a hard error
  (`AmbiguousRiskFlowPolicyError`) on an unresolved tie.

---

## Adding an entry

The test for section 1 is *"does this let a call site's target or effect
become unknowable before running the script?"* — if so, it's a
static-analysis exclusion (U005–U007's family) and no amount of
implementation effort makes it safe to add. If not, it's an ordinary
scoping cut (U001–U004's family), and revisiting it is a normal scoping
conversation rather than a "this breaks the model" one. Say which kind it
is in the entry.

A new entry needs: the construct, why it's excluded, what to do instead,
and its current enforcement state — including "not enforced" where that's
the honest answer. Allocate the next free `U` code and add the
corresponding row to [ERRORS.md](./ERRORS.md).

Where a decision was corrected along the way, write the correction
sequence, not just the final state (U004 is the worked example). A future
reader needs to see which wrong answers were already ruled out.
