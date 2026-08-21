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
- **A declared class, module, or method's behavior should be something a
  reader (often an LLM) can reason about from its own text — not
  something that can change later, conditionally, at runtime.**
  Established 2026-08-10, deciding `extend`/`include` via an explicit
  receiver (U018): the concern here is NARROWER than the risk-flow
  boundary above and separate from it — even a construct with a
  perfectly good static risk profile can still fail this test.
  `class X; extend M; end` is a one-time, textually-fixed claim about
  `X`, made at the moment `X` is defined; `X.extend(M)` — written
  ANYWHERE else, via an explicit receiver — is an ordinary statement
  that could run conditionally, in a loop, or a second time later,
  changing what `X` can do partway through a script's execution, without
  anything about its own syntax announcing that. The distinction isn't
  "did this particular script happen to make it conditional" — it's that
  the language shouldn't offer a form whose reasonability depends on
  usage discipline rather than grammar. This is the same underlying
  concern `send`/`method_missing`/`define_method` (U005) and
  `eval`/`instance_eval`/`class_eval`/`module_eval`/`instance_exec`/
  `class_exec` (U006) already embody — a declared class's behavior
  shouldn't be able to change from something other than its own
  declaration — `extend`/`include` via an explicit receiver (U018) is
  the same principle applied to mixins specifically. Worth checking any
  FUTURE construct against this same question before building it:
  "could this let a class/module/object's behavior change conditionally,
  at runtime, invisibly to someone reading the declaration alone?" — not
  just "can RiskWalker still resolve it."

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
(`->(){}`) or the `lambda { }` Kernel-method spelling (both wrap into the
same object shape — see `builtins/proc.cr`) become a real `Proc`
object. A `{ }`/`do...end` block passed to a call stays consumable
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

### U006 — `eval` / `instance_eval` / `class_eval` / `module_eval` / `instance_exec` / `class_exec` on runtime strings or blocks

**Why:** same reasoning as U005 — a script that can construct and run
arbitrary code at runtime, or run an ordinary block against an altered
`self`/binding, has no static risk profile at all. `class_eval`/
`module_eval`/`instance_exec`/`class_exec` added 2026-08-10 (see this
file's own third standing principle, above, and U018's entry below,
decided the same session): structurally the same mechanism as `eval`/
`instance_eval` — a block whose contents were never fixed at the point
the class/module/object was declared, run in a shifted context.
Previously listed in `error_catalog.cr`'s own comment as a "plausible
addition, not declared" — made an explicit, permanent exclusion once the
underlying principle was named clearly enough to declare it with
confidence rather than leave it an open question.

**Instead:** nothing; this is permanently excluded by the risk model.

**Enforcement — active since 2026-07-29 for `eval`/`instance_eval`,
2026-08-10 for the rest, runtime.** See U005 for the mechanism and why
the check happens after resolution rather than at compile time.

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

Ruby's implicit-`self` method visibility model AS A SCRIPT-DECLARABLE
FEATURE — a script writing `private`/`protected`/`public` itself to
control a class or module's own interface. A native function is
reachable via an explicit receiver on any inheriting object today;
there is no way for a SCRIPT to mark one of its own methods
unreachable from outside its own class.

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

**Instead:** nothing; every method a SCRIPT defines stays callable via
an explicit receiver, as it is today. If a script wants to signal
"don't call this," naming convention (a leading underscore, a
comment) is the available tool, same as it would be in a language with
no visibility model at all.

**Not the same thing as top-level `def`'s own implicit privacy,
shipped 2026-08-16.** A bare top-level `def` IS now unreachable via an
explicit receiver from outside `self` (`R023`) — but this is a single,
fixed, always-on rule replicating one specific thing real Ruby does
unconditionally, not a script-declarable feature; nothing about it
lets a script write `private`/`protected`/`public` itself, and every
method a script defines inside an ordinary `class`/`module` body stays
exactly as reachable as it always was. See `DEVELOPMENT.md`'s
"Top-level `def` is implicitly private" writeup for the full build-out.
This entry's own exclusion — no script-declarable visibility, for
methods defined however a script chooses to define them — is
unchanged.

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

### U010 — retired, not an exclusion

Originally filed 2026-08-05 as a possible exclusion: calling `super`
from within one `rescue` clause of a `begin` with more than one
`rescue` clause, on the theory that which superclass method `super`
reaches might depend on which clause matched.

**Resolution, 2026-08-09/10 (the same session `super` itself was
built — see `DEVELOPMENT.md`'s "Super dispatch" section): the concern
doesn't hold up.** `super`'s resolution depends entirely on the
running method's own frame (which method it's defined as, and what
class it was defined inside) — never on which `rescue` clause
happens to be executing. Every `rescue` clause of a given `begin`
runs in the SAME frame as the method body itself (no separate frame
per clause), so `super` written in any clause of a method resolves
identically no matter which one matches. Confirmed empirically, not
just by design: `spec/adjutant/super/vm_spec.cr` calls `super` from
two different clauses of the same method, matched by raising two
different exception types, and both reach the same superclass
method.

There is nothing to enforce and nothing unsupported here — an
ordinary `super` call works exactly the same inside a `rescue` clause
as anywhere else in the method. **`U010` itself is retired and will
not be reassigned to a different construct** (see `ERRORS.md`'s
identity-stability guarantee for error codes).

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
script that need to communicate. For a Regexp match result
specifically — the case this came up around, 2026-08-14, while
deciding against building real Ruby's `$~`/`$1`-`$9`/`$&`/`` $` ``/
`$'`/`$+` match globals — keep the `MatchData` `#match` returns in a
local variable; it already exposes everything those globals would
(`#[]`, `#captures`, `#pre_match`, `#post_match`, `#begin`/`#end`).
The one real (not just less-convenient) gap: real Ruby's own
`#sub`/`#gsub` block form only ever yields the matched STRING, never a
`MatchData` — `$~` is genuinely the only path to capture groups from
inside that specific block, in real Ruby too, not an Adjutant
limitation. `Regexp#match`/`String#match`'s OWN block form (yielding a
real `MatchData`, unlike `#sub`/`#gsub`'s) covers the common case
where this actually matters; re-matching the yielded substring covers
the rest, imperfectly (a pattern anchored to context outside the
matched span, e.g. a lookbehind, could behave differently re-matched
in isolation) but adequately.

**Enforcement — active since 2026-08-14, parse time.** `$name`-shaped
tokens are lexed as `GVar`, but `primary`'s `TokenKind::GVar` case
(`parser.cr`) is the ONLY place one is ever consumed anywhere in this
parser — deliberately a dead end, not a real expression node — raising
a `U011` diagnostic by name instead of falling through to the generic
`P002` "not valid here" the rest of `primary`'s fallback produces.
Covers both read (`$foo`) and write (`$foo = 1`) attempts uniformly,
since assignment-target parsing bottoms out through the same
`primary` entry point for its left-hand side. U008, U009, and
U012–U015 remain unenforced — see SCOPE.md's Error reporting group;
this closes only U011 out of that batch.

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

### U017 — Operator-method overloading (`def ==`, `def <`, `def +`, ...)

Defining a method whose name is an operator token (`==`, `===`, `<`,
`<=`, `>`, `>=`, `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `<<`, `>>`,
...) on a script class, intending the corresponding infix operator (or,
for `===`, `case/when`) to invoke it — real Ruby's operator-overloading
mechanism. `[]`/`[]=` are the same idea but structurally can't even be
written — see the Enforcement note below.

**Why:** decided 2026-08-06, found while working the `<=>` item above.
Every one of these operators (`==` included) compiles to a dedicated
opcode (`Op::Eq`, `Op::Lt`, `Op::Add`, ...) that goes straight to
`ValueOps`, which never consults a class's method table — this is the
same "arithmetic and indexing stay fixed-opcode" reaffirmation the
`<=>` decision above already makes, extended explicitly to cover `==`
too, which that decision's own text deliberately excludes from
`<=>`-derivation (real Ruby's plain `Object#==` is identity, not
`Comparable`-derived). `<=>` remains the one, sole exception — this
entry closes the door on every other operator, including `==`, not
just the ones `<=>` doesn't already cover.

**The concrete trap this closes:** every operator above already has
its own real token, and `parse_def` accepts any token as a method name
with no restriction — so `def ==(other)`/`def <=(other)`/etc. parse
successfully today, get stored as real methods on the class, and are
never called by the corresponding infix operator. This is a direct
violation of this file's own stated principle ("never silently do
something different from what was written") — worse than an outright
parse error, since it looks like correct, working Ruby right up until
a comparison silently returns the wrong answer. Found via a concrete
example script defining `X#<=`/`X#==` that parsed cleanly and then
failed two assertions silently (`x <= 5` evaluated to `false`,
`3 == x` evaluated to `false`) with no error anywhere.

**`===` joined this set 2026-08-07,** once the lexer grew a real
`TripleEq` token (`lexer.cr`'s `scan_eq`, maximal-munch ahead of the
existing `EqEq` case) — before that, `"==="` split into `EqEq` + a
stray `Eq`, and `def ===(x)` failed with a confusing, unrelated-looking
`P002` partway through the method body (the same shape of trap this
whole entry exists to prevent, just reached through a parse failure
instead of a silent no-op) rather than this clean, named rejection.
The token exists ONLY for `def`-name-position parsing — deliberately
not added to the `PRECEDENCE` table, since `a === b` as general infix
script syntax isn't something Adjutant supports or real Ruby scripts
normally write either (`case/when` is the real caller, and that's
compiler-generated dispatch, not parsed from script syntax — see
`compile_case`). `Class#===`/`Range#===` (`vm.cr`'s `exec_builtin`) are
unaffected by this entry: those are native, VM-internal dispatch for
`case/when`'s own patterns, not a script-definable method, so the
rejection and that feature coexist without conflict, same as every
other operator here.

**Instead:** define `<=>` for ordering (see the `Must Fix` entry above
— `<`/`<=`/`>`/`>=` will dispatch through it for `RubyObject`
operands). For `==`, define a differently-named method (`eql_value?`,
`same_as?`, ...) and call it explicitly rather than via `==`.

**Enforcement — active since 2026-08-06 (2026-08-07 for `===`),
compile time, for every name in the set** (`==`, `===`, `<`, `<=`, `>`,
`>=`, `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `<<`, `>>`).
`Compiler#compile_def` (`OVERLOADABLE_OPERATOR_NAMES`) checks the
method name before anything else about the def, raising a structured
`U017` with a caret on the `def` keyword (same tradeoff `U004` already
makes — no end position for the name token itself, and three
characters that are always right beats a longer span that's only
usually right). `[]`/`[]=` are deliberately absent from that set, not
an oversight: like `"==="` before it got a token, there's no combined
`[]`/`[]=` lexer token — `[`/`]` are separate tokens, so `parse_def`
(which blindly takes whatever single token follows `def` as the name)
already can't produce a `DefNode` named `[]` at all; it grabs `[`
alone and trips on the stray `]` with an unrelated, confusing parse
error before ever reaching this check. Verified via
`methods_and_calls/compiler_spec.cr`'s U017 specs, covering the
`<=>`-is-exempt regression case directly.

### U018 — `extend`/`include` via an explicit receiver

`X.extend(M)`, `obj.extend(M)`, `X.include(M)`, `obj.include(M)` — mixing
a module in via a receiver, rather than the bare, declarative statement
form (`extend M` / `include M`) written directly inside the `class`/
`module` body being mixed into. Both `extend` and `include` themselves
are fully supported (see `DEVELOPMENT.md`'s "Mixins" section) — this
entry is specifically about the explicit-receiver spelling, not the
feature as a whole.

**Why:** decided 2026-08-10, this file's own third standing principle
(see above), while confirming the shape of `obj.extend`'s exclusion.
`class X; extend M; end` is a one-time, textually-fixed claim about `X`,
made at the moment `X` is defined. Writing the same thing with an
explicit receiver, anywhere else in a script, turns it into an ordinary
statement — one that could run conditionally, in a loop, or a second
time later, changing what a class or object can do partway through a
script's execution, without anything about its own syntax announcing
that. The concern isn't whether a specific script happens to write it
unconditionally; it's that the language shouldn't offer a form whose
reasonability depends on how it happens to be used, the same underlying
concern `send`/`method_missing`/`define_method` (U005) and the `eval`
family (U006) already embody, applied here to mixins specifically.

**The concrete gap this closes:** before this was declared, both forms
simply failed to resolve — no dispatch path checks a receiver's own
class's class for `extend`/`include` the way the bare/implicit-self path
does (`VM#dispatch_call`'s self-is-rclass branch) — surfacing as a
generic, misleading "undefined method `extend`"/`"include"` (`R008`)
that reads like a typo, not a declared boundary. `SomeClass.extend(M)`
(explicit receiver on the CLASS itself, not an instance) has the
identical gap and gets the identical treatment — the distinction that
matters is bare/declarative vs. explicit-receiver, not what kind of
value the receiver happens to be.

**Instead:** write `extend M` / `include M` as a bare statement directly
inside the `class`/`module` body being mixed into.

**Not the same restriction as top-level bare `include`.** Scoped
2026-08-15, shipped 2026-08-16: a bare `include M` statement written at
the TOP LEVEL of a script (no enclosing `class`/`module` body at all) is
the same textually-fixed, one-time shape this entry treats as safe —
just with `main`'s own class (`Object`) standing in for the class/module
body, rather than one being absent. Confirmed against real `irb` before
implementing: top-level `include M` mutates `Object`'s ancestor chain
directly, and the mixed-in methods stay ordinary public instance
methods, reachable from any object via explicit receiver — not a new,
more permissive behavior Adjutant would be inventing, but the literal
thing real Ruby already does. See `DEVELOPMENT.md`'s "Bare `include` at
the top level of a script" writeup for the implementation. This entry's
own restriction — explicit receiver, anywhere, including at the top
level (`Object.include(M)`, `main.include(M)` if such a spelling
existed) — is unchanged and still applies.

**Top-level bare `extend` is NOT the same case, and stays excluded —
for a different reason than this entry.** Confirmed against a separate
real `irb` trace, also 2026-08-15: unlike `include`, top-level `extend M`
writes to a genuine per-object singleton class belonging to `main`
alone, something `RubyObject` has no storage for at all today. That's an
ordinary missing-feature gap (see [SCOPE.md](./SCOPE.md)'s "Object
model" group), not this entry's explicit-receiver concern — a bare
top-level `extend M` currently still falls through to this same
`EXCLUDED_METHODS` catch, same as before `include`'s fix, simply
because nothing yet resolves it any other way.

**Enforcement — active since 2026-08-10, runtime.** Same mechanism as
U005/U006 (`EXCLUDED_METHODS`, checked after ordinary resolution fails —
see U005's own entry for why after, not at compile time). The bare/
declarative form never reaches this check at all, since it resolves
successfully via a different path first; this table entry is only ever
consulted once that path has already failed, which happens precisely
for the explicit-receiver forms this entry covers.

### U019 — `proc { ... }` (the `Kernel`-method spelling)

`->(...) { ... }` and `lambda { ... }` (the latter added 2026-08-19,
alongside this exclusion) both produce a real `Proc` object, correctly
matching real Ruby. `proc { ... }` — a Ruby user's other obvious first
reach for a Proc — is deliberately not given the same treatment.

**Why:** decided 2026-08-19, while implementing `lambda { ... }`. Real
Ruby's `proc { }` has different runtime behavior from `lambda { }`/
`->(){}`: lenient arity (extra or missing arguments don't raise), and a
bare `return` inside it escapes the ENCLOSING method rather than just
returning from the proc itself. Wrapping a `proc { }` block into the
same object `lambda`/`->(){}` already build (as an earlier version of
this change did) would have given it `lambda`'s strict arity and
local-only `return` instead — a script relying on either real-Ruby
behavior would get a silently wrong answer (a spurious `ArgumentError`,
or a `return` that stops one frame short of where it should), not
merely a smaller, correct subset of Proc. Real Proc semantics — in
particular the non-local `return`, which needs a `return` to unwind
past the proc's own frame into whatever method happened to be running
when it was called — are a genuine, separate VM feature, not something
this pickup was scoped to build.

**Instead:** use `lambda { ... }` or `->(...) { ... }`.

**Enforcement — active since 2026-08-19, runtime.** Same mechanism as
U005/U006/U018 (`EXCLUDED_METHODS`, checked after ordinary resolution
fails). A script defining its own `proc` method is unaffected — this
table is only ever consulted once ordinary resolution has already
failed to find one.

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
