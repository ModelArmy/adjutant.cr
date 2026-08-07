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
now exists, and **every enforced entry below — U001 through U004 — is
wired to it.** Their errors carry a structured `Diagnostic`, render with
the offending source line, and draw their wording from the catalog rather
than the raise site. U001 and U004 are caught by the compiler and get
carets; U002 and U003 are caught by the VM, which records a line but no
column, so those render the source line without a caret row.

Every entry below now reports its own code.

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
(`compiler.cr`). Verified via `methods_and_calls/compiler_spec.cr`'s
"rejects &blk param
capture at compile time", plus a sibling regression check confirming
ordinary `yield` — a separate mechanism — is untouched by the guard.

Revisit as a new, separate scope item if a real script needs to hold and
defer-call a block.

**Also covers:** `&obj` calling `to_proc` on a non-`Symbol` receiver at
a call site (found 2026-08-05 in the mruby full-repo sweep,
`test/t/proc.rb`) — not a separate decision, just one more manifestation
of the same underlying gap (no first-class block/proc capture), since
`&obj` needs somewhere to bind the resulting proc.

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

**Enforcement — active since 2026-07-27, runtime; migrated to a
structured `U002` diagnostic 2026-07-28.** Until then nothing
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
rather than a dedicated check; migrated to a structured `U003` diagnostic
2026-07-28, which is also when reopening stopped sharing one message with
ordinary constant reassignment (now R001).** `Op::MakeClass` always
allocates a fresh, disconnected `RubyClass` for every `class Foo; end` it
compiles, with no reuse-if-already-exists check, so the reassignment guard
in `Op::SetConstant` is what converts a reopen into a loud error instead
of silent data loss.

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
   folded into `methods_and_calls/compiler_spec.cr`): that's wrong. `Op::DefSingleton`
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
`methods_and_calls/compiler_spec.cr`'s nested-def specs, covering the
`def self.foo` shape,
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

**Enforcement — active since 2026-07-29, runtime.** Until then these names
were simply undefined, so a script using one got a generic
undefined-method error that never said the construct was deliberately
excluded — the same failure shape the 2026-07-27 audit removed from
U001–U004, and worse here, because these are the permanent kind: an LLM's
natural response to "undefined" is to retry with a variation, and every
variation fails identically.

Checked in `dispatch_call` **after** normal resolution fails, not at
compile time. Compile-time rejection was the original proposal and is
wrong: a script may define its own method with one of these names
(`class Mailer; def send; ...; end; end` is valid Ruby and valid
Adjutant), and rejecting the name outright would break it. Reaching the
check means the name resolved to nothing, so the script meant Ruby's
construct. Raised as a `NameError` like any unresolved name, so a script
rescuing `NameError` still catches it; the code is what says it will never
resolve. Verified via `classes_and_modules/vm_spec.cr`, including the
own-method case.

The enforced set is deliberately narrow — `send`, `public_send`,
`__send__`, `method_missing`, `define_method`. Names like `class_eval`,
`instance_exec`, `methods`, and `instance_variable_get` pose the same
hazard but are not declared exclusions here, and listing them would assert
"never coming" without that decision having been made.

### U006 — `eval` / `instance_eval` on runtime strings

**Why:** same reasoning as U005 — a script that can construct and run
arbitrary code at runtime has no static risk profile at all.

**Instead:** nothing; this is permanently excluded by the risk model.

**Enforcement — active since 2026-07-29, runtime.** See U005 for the
mechanism and why the check happens after resolution rather than at
compile time.

### U007 — Reflection exposing native/Crystal internals

Arbitrary FFI, `ObjectSpace`-style introspection, and similar.

**Why:** not needed by anything on the roadmap, and it would let a script
route around the effect boundary (`EffectHandler`/`ModuleRegistry`)
entirely.

**Instead:** register what the script legitimately needs as a native module
with a declared risk profile.

**Enforcement — partial, since 2026-07-29, runtime.** `ObjectSpace` is
reported as U007 rather than as an uninitialized constant. This goes
through constant resolution rather than method dispatch, unlike U005/U006
— the same after-resolution-fails principle, a different lookup path.

Only `ObjectSpace` is named. There is no list of reflection METHOD names to
enforce, because none is declared here: this entry describes a category
("arbitrary FFI, `ObjectSpace`-style introspection") rather than an
enumerated set, and inventing the enumeration while enforcing it would be
deciding scope by implementation. Anything else reflective currently
reports as an ordinary undefined name.

### U008 — `private`/`protected`/`public`

Ruby's implicit-`self` method visibility model. A native function or
top-level `def` (both land on `Object`) is reachable via an explicit
receiver on any inheriting object today — there is no way to mark a
method unreachable from outside its own class.

**Why:** decided 2026-08-05, during a session filtering the mruby-derived
gap survey by value against Adjutant's actual use case. Visibility exists
in real Ruby to protect an interface from *other* authors calling it in
ways the original author didn't intend. Adjutant scripts are
LLM-generated, typically single-authored and often short-lived or
narrow in scope even when reused — there's no second author whose
misuse visibility would be defending against. Adding the mechanism
mainly introduces a new failure mode (an agent calling something that
should have been private, and getting an error for a distinction that
serves no purpose in this use case) without a corresponding safety
benefit here.

**Instead:** nothing; every method stays callable via an explicit
receiver, as it is today. If a script wants to signal "don't call this,"
naming convention (a leading underscore, a comment) is the available
tool, same as it would be in a language with no visibility model at all.

**Enforcement — not yet enforced.** `private`/`protected`/`public` are
currently either undefined names (if used as bare calls) or silently
inert (if a script defines its own method with one of those names,
which works exactly like any other method definition — there's no
special parsing for the visibility-declaration call shape at all). Not
yet migrated to a structured diagnostic; tracked as part of the U008–
U011 batch in [SCOPE.md](./SCOPE.md)'s Error reporting group.

### U009 — `Struct.new`

Ruby's `Struct.new(:a, :b) { ... }` — dynamically synthesizing a class
from a field list, with generated accessors, `==`, `to_s`/`inspect`, and
`to_a`/`to_h` for free.

**Why:** decided 2026-08-05, in the same filtering session as U008.
Structurally adjacent to `Class.new`/`Module.new` (U002) — both
dynamically generate a class at runtime rather than declaring one
statically — and every real use case a `Struct` covers (a small,
named-field data bag) is already fully expressible with a plain class:

```ruby
class Point
  attr_accessor :x, :y
  def initialize(x, y)
    @x = x
    @y = y
  end
end
```

The only genuine loss is the free `==`/`to_s`/`to_a`/`to_h` real
`Struct` derives automatically — a real but minor cost next to the
dynamic-class-generation cost of supporting `Struct` at all, and one an
LLM reaches for reliably in its more verbose, explicit form.

**Instead:** declare a plain class with `attr_accessor` and an
`initialize`, as above.

**Enforcement — not yet enforced.** `Struct` currently resolves as an
uninitialized constant (there is no bootstrap `Struct` class the way
there is for `Class`/`Module`/`Object`), so a script gets a generic
undefined-constant error rather than one naming `Struct` specifically as
a deliberate exclusion. Tracked as part of the U008–U011 batch in
[SCOPE.md](./SCOPE.md)'s Error reporting group.

### U010 — `super` across multiple `rescue` clauses per `begin`

Calling `super` from within one `rescue` clause of a `begin` that has
more than one `rescue` clause, where the semantics of which superclass
method `super` should reach depend on which clause is active.

**Why:** decided 2026-08-05, in the same session multiple `rescue`
clauses themselves were promoted to `Must Fix` (see
[SCOPE.md](./SCOPE.md)). Genuinely obscure even in human-written Ruby —
the ordinary combination of `super` and `rescue` (a `rescue` clause that
doesn't itself call `super`) is unaffected and remains fully supported;
this exclusion is narrowly the *interaction* of the two, not either
construct on its own.

**Instead:** restructure the rescue body to call the intended method
explicitly rather than via `super`, or move the `super` call outside the
`rescue`/`begin` entirely if the intent allows it.

**Enforcement — not yet enforced.** Calling `super` inside a
multi-clause `rescue` today either behaves unpredictably or resolves to
whatever `super`'s ordinary (single-clause-unaware) implementation
does — not yet audited precisely, since multiple `rescue` clauses
themselves don't parse yet (see the `Must Fix` item). Enforcement here
is gated on that item landing first, and is tracked as part of the
U008–U011 batch in [SCOPE.md](./SCOPE.md)'s Error reporting group.

### U011 — `$globals`

Ruby's `$`-prefixed global variables — a single mutable namespace
visible from anywhere in a script, independent of lexical scope.

**Why:** decided 2026-08-05, in the same filtering session as U008/U009.
Beyond being rarely used even in human-written Ruby, a global mutable
channel is precisely the kind of implicit side-channel Adjutant's IFC/
risk-flow model (`EffectHandler`/`ModuleRegistry`, provenance tracking —
see the IFC design arc) exists to make explicit and traceable. Every
other way data moves through an Adjutant script — parameters, return
values, instance variables — is visible to the risk aggregator by
construction; a global would let two unrelated parts of a script
communicate outside any of those paths, undermining the same
static-traceability property the `send`/`eval`/reflection exclusions
(U005–U007) protect from a different angle.

**Instead:** pass values explicitly as parameters/return values, or use
an instance variable on an object shared between the parts of the
script that need to communicate.

**Enforcement — not yet enforced.** `$name`-shaped tokens are lexed as
`GVar` but the parser never consumes them into a usable node — so a
script writing `$foo = 1` fails at parse time today, but with a generic
parse error rather than one naming globals as a deliberate exclusion
tied to the IFC model. Tracked as part of the U008–U011 batch in
[SCOPE.md](./SCOPE.md)'s Error reporting group.

### U012 — Numbered block parameters (`_1`, `_2`)

Real Ruby's implicit block-parameter shorthand — `arr.map { _1 * 2 }`
instead of `arr.map { |x| x * 2 }`.

**Why:** decided 2026-08-05, triaging the mruby full-repo sweep
(`test/t/syntax.rb`). Pure convenience over named block parameters,
which already fully cover the capability with no loss of
expressiveness — this is the cleanest possible exclusion case in that
sense. Also a newer Ruby idiom (3.0+) with less representation in
training data than named parameters, so lower probability an agent
reaches for it by default even before considering support.

**Instead:** name the block parameter explicitly (`{ |x| x * 2 }`).

**Enforcement — not yet enforced.** `_1`/`_2` parse today as ordinary
identifiers — ordinary undefined-variable errors if referenced without
being otherwise assigned, not a diagnostic naming this as a deliberate
exclusion.

### U013 — Endless method definitions (`def square(x) = x * x`)

Real Ruby's one-line method-definition shorthand (3.0+).

**Why:** decided 2026-08-05, same triage session as U012. Purely
cosmetic — zero expressiveness difference from an ordinary multi-line
`def`, which is unaffected and fully supported.

**Instead:** write the method body on its own line(s) with `def`/`end`
as usual.

**Enforcement — not yet enforced.** `def square(x) = x * x` fails to
parse today (`parse_def` expects a body followed by `end`, not `=`),
with a generic syntax error rather than one naming this construct.

### U014 — `class << self` (singleton-class block syntax)

Real Ruby's block form for opening a class's singleton class, most
commonly used to define several class methods at once without
repeating `self.` on each one.

**Why:** decided 2026-08-05, same triage session as U012/U013.
`def self.foo` — already fully supported — covers the same capability
per-method with no loss; `class << self` is convenience syntax for
defining several class methods together, not new expressiveness.

**Instead:** prefix each class method with `self.` individually
(`def self.foo; end`).

**Enforcement — not yet enforced.** `class << self` fails to parse
today (`<<` after `class` isn't a recognized construct), with a
generic syntax error rather than one naming this construct.

### U015 — `undef`, `method_added`/`singleton_method_added` hooks

Real Ruby's `undef method_name` (permanently removing a method from a
class) and the `method_added`/`singleton_method_added` callback hooks
(invoked automatically whenever a method is defined/added).

**Why:** decided 2026-08-05, triaging the mruby full-repo sweep
(`test/t/methods.rb`). `undef` has near-zero use in short,
agent-authored scripts — removing a method after the fact isn't a
pattern this use case calls for. The two hooks are reflection-adjacent
metaprogramming, the same family U005–U007 already exclude for the
same reason (letting a script observe/react to its own method-table
changes has little pragmatic value here and cuts against static
resolvability) — grouped with those rather than treated as a new
decision. Distinct from `Class#inherited` (tracked separately in
[SCOPE.md](./SCOPE.md) as `Will Fix`): that hook has a genuine
pragmatic use (registry/discovery patterns) with no equivalent
already-supported spelling, which these two don't.

**Instead:** for `undef`, simply don't call the method (or don't define
it in the first place). For the hooks, there's no equivalent — a script
needing to know what methods exist should track that explicitly itself
(e.g., appending to an array at each definition site) rather than
relying on an automatic callback.

**Enforcement — not yet enforced.** `undef` fails to parse today (no
`undef` keyword token); the two hooks are ordinary undefined-method
errors if a script tries to define `self.method_added` expecting it to
be called automatically — nothing currently invokes it either way, so
defining it silently does nothing rather than erroring.

### U016 — `begin...end while cond` / `begin...end until cond` (do-while)

Real Ruby gives this one specific form of the `while`/`until`
modifier different semantics than every other use of the same keyword:
wrapping a `begin...end` block runs the body once *before* the first
condition check (do-while), where `expr while cond` for any other
expression always checks first and may run zero times — `x -= 1 while
x > 10` never touches `x` if `x` starts at `10`, but `begin; x -= 1;
end while x > 10` decrements it once regardless. Adjutant supports the
ordinary form (`expr while cond`, checking first, same as `while
cond...end` written postfix); this entry excludes only the `begin`-
wrapped form.

**Why:** decided 2026-08-06. Found while tracing a bug in
`compile_modifier_while` (`compiler.cr`): that method compiled every
`ModifierWhile` node with check-*last* semantics unconditionally,
correct only for the `begin`-wrapped form and silently wrong for
the far more common plain-expression one — no test anywhere had
exercised either form at the VM level before, so neither the bug
nor the distinction it depended on had ever surfaced. Fixing the
plain-expression case properly meant deciding what to do with the
do-while case it had been conflated with, rather than trying to make
one AST shape (`ModifierWhile` wrapping a `BeginNode`) silently mean
something different from every other `ModifierWhile` depending on what
it happens to wrap. The do-while form is also easy to misread — the
body always runs once before the condition is checked at all, unlike
every other `while`/`until` — and it's rarely used and generally
discouraged in Ruby style guides for that exact reason. Adjutant
already has `while`/`until` covering the same need with the check made
explicit and visible rather than implied by which block-opening
keyword was used.

**Instead:** use `loop` with a `break` for the exit check — it runs
the body once by construction, with no repetition of the body itself:
`begin; body; end while cond` becomes `loop do; body; break unless
cond; end`.

**Enforcement — active since 2026-08-06, both forms, at the point
each reaches the pipeline stage that can tell them apart.** A bare
`begin...end while cond` statement (no assignment — by far the more
natural way to write this) is caught at *parse* time
(`Parser#reject_do_while`, checking for a `while`/`until` token
immediately following a `begin...end` statement, before any
`ModifierWhile` node is ever built for it) since that form would
otherwise fall through to a confusing, unrelated "`while` is missing
its `end`" (P003) with no hint that `begin`/`ensure` had anything to
do with it. The assigned form (`x = begin...end while cond`, and its
`+=`/`-=`/`*=`/`/=`/`%=`/`||=`/`&&=` siblings) does reach a real
`ModifierWhile` node, so it's caught at *compile* time instead
(`Compiler#compile_modifier_while`, via the `do_while_begin` helper,
which unwraps one layer of assignment before checking for a
`BeginNode` — an earlier version of this check tested the
`ModifierWhile`'s body directly and missed every assigned case, since
the body there is the assignment itself, not the `begin...end`) — two
different pipeline stages for the same construct, not two different
decisions; each is simply the earliest point that form's shape is
actually knowable. Verified via `control_flow/vm_spec.cr` (the
check-first fix for the ordinary form), `control_flow/parser_spec.cr`
(the bare-statement rejection), and `begin_rescue_ensure/compiler_spec.cr`
(the assigned-form rejection, including the
compound-assignment case).

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
