# Scope

Persistent record of outstanding work and deliberate non-goals. Updated as
part of any session that adds, resolves, or reprioritizes an item — this
file is the source of truth for "what's left," not the handoff document,
which only carries context on how to work, not the item list itself.

An item lives in exactly one of the three sections below. Moving an item
between sections (e.g. `Will Fix` → `Must Fix` once it starts blocking
something) is itself a real edit — leave a one-line note in the entry
about when/why the priority changed, rather than silently re-filing it.

Items should be concrete enough that someone with no session history could
pick one up and know where to start looking (a file, a method, a design
conversation reference) — not just a restated symptom.

## Must Fix

Blocking, or actively causing incorrect behavior in normal use. Ordered
roughly by dependency, not necessarily by importance — an item lower down
may unblock ones above it.

- **Piece C — wrap lambdas as a real `Proc` builtin class.** A `Lambda`
  literal currently compiles to a bare `Value.proc(sproc)`, not wrapped in
  any `RubyObject`. This is what still allows `dbl(3)` (a local holding a
  lambda) to be *directly* callable via the VM's own call machinery
  without going through a real `#call` method — the last piece of the
  original `dbl`/`def dbl` collision investigation. Needs: (1) a `Proc`
  `RubyClass` with a native `#call`, mirroring how `Range` was added
  (`src/adjutant/builtins/range.cr` as the template); (2) `compile_lambda`
  changed to emit a `Value.robject(Proc-instance)` instead of a bare
  `Value.proc(sproc)`. Also closes two already-documented side gaps for
  free: `.class`/`.proc?` not resolving for a bare lambda `Value` (no
  `builtin_class_for` case for a proc today), and `->(){}.call(...)` not
  existing as a language feature at all.
- **Piece D — risk-walking for blocks/lambdas.** `RiskWalker` never walks
  a `BlockNode`'s or `Lambda`'s body at all today — a block passed to
  `Array#each { risky_call }` is completely invisible to static risk
  assessment; only the `each` call itself is priced. Design direction
  agreed in the 2026-07-15 conversation: walk a `Lambda`'s body eagerly
  (same treatment `walk_script_method` gives a `def`, once C makes a
  `Lambda` a first resolvable thing rather than a bare proc `Value`);
  fold a `BlockNode`'s body into the risk of the call it's attached to,
  wrapped as `iterated: true` (same shape `walk_iterated` already gives
  `while`/`for`), using the *enclosing* env (closure semantics), not
  method-only scope. `yield`/a stored lambda's deferred `.call` stay out
  of scope — no runtime mechanism calls a stored proc later yet (see C).
  Depends on C landing first (a `Lambda` needs to be a resolvable
  `RubyObject`, not a bare `Value`, before the walker can memoize/track
  it the way it does `ScriptProc`s for `def`s).

## Will Fix

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

- **No true per-instance singleton methods on `RubyObject`.** `Op::DefSingleton`
  (`def self.foo` when `self` is a `RubyObject`, not a `RubyClass`)
  targets the receiver's own *class* instead — `RubyObject` has no
  singleton-method table of its own. Correct in practice for the one case
  that matters today (`def self.foo` at top level, where `self` is always
  `main`) but means the method is callable as `Object.foo`, not via a
  later bare `foo`. See `DEVELOPMENT.md`'s "self at every level" section
  and `Op::DefSingleton`'s own comment in `vm.cr`. A real per-instance
  singleton-method table on `RubyObject` would close this properly.
- **No implicit-`self` privacy/visibility model.** Adjutant has no
  `private`/`public`/`protected` at all — a native function or top-level
  `def` (both land on `Object`) is reachable via an explicit receiver on
  any inheriting object (`Foo.new.puts_equivalent`), unlike real Ruby's
  Kernel methods, which are private. Found while fixing piece B (the
  root-scope work); see `root_scope_spec.cr`'s own test coverage of the
  current (permissive) behavior.
- **`for`/`while`'s do-ambiguity fix pattern not applied elsewhere.** The
  `@no_do_block` suppression flag (parser.cr) fixing `for x in a do`/
  `while cond do` mis-parsing was scoped to those two constructs. The
  same shape of bug (`block_follows_no_paren?` mis-firing on a bare
  identifier immediately before a construct's own `do`) was flagged as
  likely present in `parse_until`/anywhere else accepting an optional
  trailing `do` — not verified beyond `while`/`for`.
- **`Array`/`Hash` as a `Hash` key hashes by reference, not content.**
  `Value` has no custom `hash(hasher)` for the `array?`/`hash?` cases, so
  `{[1,2] => "a"}[[1,2]]` (a different but `==`-equal `Array`) won't find
  the entry. See `ValueOps.equal?`'s own comment (`value_ops.cr`) and
  `DEVELOPMENT.md`'s "Not yet implemented" list.
- **String repetition (`"ab" * 3`) not implemented.** `ValueOps.op`
  (backing `*`) has `Integer`/`Float` cases only.
- **Symbol-shorthand hash literal syntax (`{k: v}`) not parsed.** Only
  hash-rocket (`{"k" => v}`) works today.
- **No structured audit-trail export beyond `RiskFlowLog` itself.**
  Nothing turns a `RiskFlowLog` into a saved/replayable session record.
  Carried forward from the original 2026-07-14 handoff, still open.
- **The approval cache** (avoid re-prompting for an already-approved
  origin→sink flow within one script run) — still not designed. Carried
  forward from the original 2026-07-14 handoff.
- **Eager vs. lazy ambiguous-priority policy validation** for
  `RiskFlowPolicy` — still not decided. Carried forward from the original
  2026-07-14 handoff.
- **No real File IO/HTTP native module** — only `SampleModule`'s simulated
  I/O exists. Carried forward from the original 2026-07-14 handoff.
- **Older, longer-standing language gaps**, unchanged since the original
  2026-07-14 handoff and not touched by any session since: assignment-as-
  real-expression (`c = b = 5` doesn't parse), `include`/mixins, `super`
  across multiple `rescue` clauses per `begin`, `$globals` (lexed as
  `GVar` but never consumed by the parser — see `DEVELOPMENT.md`'s
  scoping section), heredocs/`%w[]` literals, multi-level closures,
  `Range` for non-`Integer`/non-`succ`-having bound types beyond what's
  already generic, exponential float literals (`1e10`), `<=>` for
  `Integer`/`Float`, a shared `Numeric` ancestor, `respond_to?`'s blind
  spot (`x.respond_to?(:to_s)` is `false` even though `x.to_s` works).

## Won't Fix

Deliberately out of scope, with the reasoning that closed the door —
revisit only if the stated reason no longer holds.

- **`Class.new`/`Module.new`.** Explicit cut from the Object/Class/Module
  design conversation (2026-07-14 arc) — this bootstrap only makes
  `Class`/`Module` exist as real `RubyClass`es for `.class`/`is_a?`/
  `superclass` to work correctly; not meant to be instantiable from
  script.
- **A per-parameter declarative provenance schema** for
  `declare_sensitivity` (declare provenance at `define_native`
  registration time, instead of the current call-site-driven API).
  Rejected during the original IFC design arc — Ruby's dynamic arity
  (variadic functions, optional args, role-depends-on-other-args
  patterns) has no fixed positional contract a schema could describe
  reliably.
- **Adjutant should never generate end-user-facing prompt text itself**
  (for i18n reasons) — the agent-facing API for consuming a
  `RiskFlowDecisionRequest` stays documentation/samples, not new core
  API surface. Decided during the original IFC design arc.
- **Wildcard-counting or array-order-as-priority for `RiskFlowPolicy`
  pattern specificity.** Both considered and rejected during the
  original IFC design arc — hostnames get more specific reading left,
  paths reading right; no single syntax-driven specificity rule
  generalizes across both. `priority` is an explicit field instead, with
  a hard error (`AmbiguousRiskFlowPolicyError`) on an unresolved tie.
