# Scope

Persistent record of outstanding work. Updated as part of any session that
adds, resolves, or reprioritizes an item — this file is the source of
truth for "what's left," not the handoff document, which only carries
context on how to work, not the item list itself.

Deliberate non-goals are **not** tracked here; they live in
[UNSUPPORTED.md](./UNSUPPORTED.md). See the closing section for the
distinction.

An item lives in exactly one of the two sections below. Moving an item
between them (e.g. `Will Fix` → `Must Fix` once it starts blocking
something) is itself a real edit — leave a one-line note in the entry
about when/why the priority changed, rather than silently re-filing it.

Items should be concrete enough that someone with no session history could
pick one up and know where to start looking (a file, a method, a design
conversation reference) — not just a restated symptom.

## Must Fix

Blocking, or actively causing incorrect behavior in normal use. Ordered
roughly by dependency, not necessarily by importance — an item lower down
may unblock ones above it.

- **`===` fallback semantics for `Class` and `Range` — a correctness
  bug, not a new capability.** Also surfaced 2026-08-05 in the same
  session. `case/when` already compiles to a genuine `Op::Call` of
  `"==="` per branch (`compiler.cr`'s `compile_case`). The bug is the
  *built-in* fallback: `vm.cr`'s `when "==="` branch is just
  `values_equal?`, i.e. plain `==`, for every receiver. Concretely,
  `case x; when Integer` and `case x; when 1..10` both compile and run
  with no error, and never match, because `x == Integer` and `x ==
  (1..10)` are always false — a silent wrong answer on two of the most
  idiomatic `case/when` forms in real Ruby.

  **Correction, 2026-08-06 — the dispatch mechanism IS also part of
  the problem, not just the fallback.** Found while tracing the `<=>`
  item above, which had the identical bug in its own
  `compile_spaceship`: `compile_case` never sets the receiver bit
  (`0b10`) on its `Op::Call` either, so `dispatch_call` never even
  attempts receiver-based method lookup for `"==="` — every `case`
  branch falls straight to the generic `values_equal?` fallback below
  regardless of what's registered on the pattern's own class. Today
  this is low-consequence only because nothing CAN register a real
  `"==="` yet — no script class can (`U017`, structural: no `"==="`
  lexer token exists at all, confirmed via a live parse-error repro),
  and no native class does either — but the fix for `Class`/`Range`
  below must ALSO set this bit, or it will silently break the moment
  anything else ever tries to register a real `===`, the same shape
  of bug all over again. `is_a_target?`, the class already has for
  `is_a?`/`kind_of?` and the fix below reuses, dispatches directly by
  Crystal method call rather than through `Op::Call` at all, so it
  is NOT affected by this specific bit — but wiring `Class#===`/
  `Range#===` in as real `native_methods` entries (the more
  Ruby-consistent option, open question below) would be.

  Fix is narrowly scoped to native semantics for two receiver types,
  no opcode changes, no new overloadability:
  - `Class#===` → is-instance-of. `vm.cr` already has a reusable
    `is_a_target?` helper backing `is_a?`/`kind_of?` — reuse it here
    rather than writing new logic.
  - `Range#===` → is-member-of (`<=`/`>=` against the range bounds, or
    `<=>` if bounds aren't plain numerics).
  - Every other receiver (no built-in `===` of its own) keeps falling
    back to `==`, which is correct — real Ruby's default
    `Object#===` genuinely is `==`, so this case needs no change.

  Open question carried over from the `<=>` item's own discussion,
  not yet decided: implement `Class#===`/`Range#===` as genuine
  `native_methods` entries (reachable via `obj.===(x)` too, matching
  how `is_a?`/`kind_of?` already work, and requiring the receiver-bit
  fix above) or as another special-cased branch inside `exec_builtin`
  alongside the `==` fallback (simpler, but `case/when`-only). Lean
  toward the former for consistency, but worth confirming before
  starting.

  Depends loosely on the `<=>` item (now done): `Range#===` against
  custom Comparable-style objects benefits from `<=>` dispatch
  existing, but the common integer/float range case doesn't need it.

- **Multiple `rescue` clauses per `begin`, and `rescue A, B` (multiple
  exception types on one clause).** Promoted from the long-standing
  language-gaps backlog 2026-08-05, after a design conversation about
  whether Adjutant should keep real Ruby exception syntax at all
  (decision: yes — an LLM's exception-handling fluency is
  pattern-retrieval from a saturated Ruby training corpus, not novel
  reasoning, so the usual "exceptions are hard for LLMs" argument
  doesn't hold for a proper-Ruby-subset specifically; see that
  session's chat). Currently a script can write exactly one `rescue`
  per `begin`, catching one type — real Ruby's "catch this OR that
  specific type, handle other types separately" is a basic
  error-handling shape and not currently expressible at all. Also the
  most-flagged single gap across the `spec/scripts/mruby/exception.rb`
  survey (2026-08-05). `parse_begin`/`BeginNode` (parser.cr/ast.cr) is
  where the single-clause assumption lives today.

- **Symbol-shorthand hash literal syntax** (`{k: v}`). Promoted from
  Parser/lexer gaps 2026-08-05 — not because the fix is hard (it
  isn't; see the original entry below, unchanged in substance), but
  because of hit-probability: this is the overwhelmingly dominant
  hash-literal spelling in the Ruby corpus any Ruby-trained model
  draws on, more so than hash-rocket. Left as `Will Fix`, this is a
  silent parse-failure risk on the single most probable way an agent
  writes a hash literal — including the option-hash shape (`retries:
  3, timeout: 10`) the upcoming core API work will lean on directly,
  both in the API's own sample/test scripts and in agent-generated
  calls against it. `Parser#parse_hash_or_block_brace`
  (parser.cr) only ever calls `expect(TokenKind::HashRocket)` today —
  see the original Parser/lexer entry for the precise gap, unchanged.

- **`Class.new(name: ...)` can't reach a keyword-declaring
  `initialize`.** Promoted from Object model 2026-08-05, ahead of the
  core-API-library work: an options-heavy native class
  (`Config.new(retries: 3, timeout: 10)`-shaped) is the natural
  constructor pattern that work will reach for, and today any keyword
  argument to `.new` raises `R012` unconditionally regardless of
  whether the target class declares matching keyword params. Blocks
  the *shape* of the API being designed, not just a script author's
  convenience — see the original Object model entry below (unchanged)
  for the precise trace (`VM#invoke` needs `kwargs` threaded through
  its own signature, one layer the 2026-08-04 keyword-args arc didn't
  touch).

- **`dup`/`clone`/`initialize_copy`.** Promoted from the mruby-derived
  gap survey 2026-08-05, ahead of the core-API-library work. No
  object-copying mechanism exists at all today — a script wanting a
  modified variant of an object (a config, a response-shaped object)
  has to hand-write a copy constructor per class, which is exactly the
  kind of boilerplate an LLM either omits or gets subtly wrong (misses
  a field added later). Narrow and mechanical, no design question, and
  stdlib objects that hold state are exactly where this gap will bite
  once real APIs exist to copy. Not yet traced to a specific file/
  method — starting point is wherever `RubyObject` instance fields are
  enumerated for construction (see `#construct_object`/`#invoke` in
  `vm.cr`, already touched by the kwargs item above).

- **Runtime diagnostics have no carets** (`Frame` records a line but no
  column). Promoted from Error reporting 2026-08-05 on a
  turn-churn argument specific to this use case: the cost of an
  under-specified error isn't primarily human readability, it's how
  much a small/local model must *infer* versus *read* to fix it. A
  dense line (`foo(bar.baz, qux[i])`) failing with a line-only error
  gives a weaker model no way to tell which subexpression was at
  fault — it's exactly the shape of ambiguity that produces a wrong
  guess, a resubmission, a different error on the same line, and
  another wasted turn, and that failure mode gets worse specifically
  for the weaker models this project targets. Promoted as a priority
  call, not a claim that the fix is now cheap — the entry below
  (unchanged) still flags per-instruction bytecode cost as unverified;
  that tradeoff surfaces when the work is picked up, not before.

- **`defined?` doesn't exist — no token, no parsing, at all.** Found
  2026-08-05 in the mruby full-repo sweep (`test/t/syntax.rb`'s
  "defined? on statically-decidable operands" and its two sibling
  tests). Real Ruby's `defined?(x)` is a common defensive-programming
  idiom (`defined?(x) ? x : default`) for checking whether a local,
  constant, or method resolves before touching it — a natural pattern
  for an agent writing cautious code, and not something
  `respond_to?`'s existing gap (tracked separately) covers, since that
  only applies to methods, not locals/constants. No workaround an
  LLM would reliably reach for. Not yet traced to a starting file/
  method — needs a new keyword/token, parser support, and a real
  runtime check per operand kind (literal/expression, `self`, local,
  method, constant, global — the last excluded per U011 either way).

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

Grouped by capability so adjacent work is easy to spot — within a group,
still roughly ordered by how cheap/independent the fix is.

### Parser / lexer gaps

Small, mechanical, independent of each other — good candidates for quick
wins.

- **Call-site splat/double-splat expansion (`foo(*args)`,
  `foo(**opts)`), and `def foo(...); bar(...); end` argument-forwarding
  shorthand.** Def-site `*args` collection already works; what's
  missing is *spreading* an existing array/hash back out at a call
  site — needed for delegation/wrapper patterns ("call this other
  method with whatever I was given"), a common shape in agent-
  generated code. Not yet traced to specific parser/compiler locations.
  The `...` forwarding shorthand (found 2026-08-05 in the mruby
  full-repo sweep, `test/t/syntax.rb`'s "argument forwarding") is
  real Ruby 2.7+ sugar over the same underlying capability — once
  call-site splat/double-splat exists, `...` is a terser spelling of
  `(*args, **kwargs, &blk)`, not a separate mechanism; worth
  implementing together or `...` shortly after, not as an independent
  design question.
- **`raise`/`super` don't get the same space-before-`(` fix
  `parse_identifier_or_call` got.** Flagged 2026-07-26 while fixing
  `eq (6/3), 2` (see `DEVELOPMENT.md`'s Parser section) — `parse_raise`
  and `parse_super` (`parser.cr`) both still have the identical
  unconditional `if at_kind?(TokenKind::LParen)` pattern that bug was
  in, so `raise (x), y`-shaped code would misparse the same way.
  Deliberately not fixed alongside the reported bug (would have
  silently widened that session's scope); pick up using
  `Token#space_before?` the same way `parse_identifier_or_call` does,
  if ever actually hit.
- **`for`/`while`'s do-ambiguity fix pattern not applied elsewhere.** The
  `@no_do_block` suppression flag (parser.cr) fixing `for x in a do`/
  `while cond do` mis-parsing was scoped to those two constructs. The
  same shape of bug (`block_follows_no_paren?` mis-firing on a bare
  identifier immediately before a construct's own `do`) was flagged as
  likely present in `parse_until`/anywhere else accepting an optional
  trailing `do` — not verified beyond `while`/`for`.

Symbol-shorthand hash literal syntax (`{k: v}`) — same underlying gap
as originally filed here — was promoted to `Must Fix` 2026-08-05; see
that entry above for current status.

### Verified only up to compile time, never actually run

Constructs the parser and compiler both have real, non-trivial code
paths for, but with zero test coverage that actually executes them
through the VM — so "does this work" is currently an assumption, not a
checked fact. Worth taking seriously as its own category rather than
folding into ordinary missing-feature gaps: this exact shape (a
complete-looking implementation nobody had ever actually run) is
precisely what `redo`'s `LoopScope#body_pos` bug and
`compile_modifier_while`'s check-last-for-everything bug both turned
out to be, found 2026-08-06 only because that session's fix happened
to need a test that finally exercised them. Nothing here is *known*
broken — only unconfirmed, which the pattern above suggests is not the
same as fine.

- **`case`/`when` has no VM-level test anywhere in the repo.** Found
  2026-08-06 while surveying spec coverage for an unrelated reorg.
  `compile_case` (`compiler.cr`) is a real, seemingly complete
  implementation, and `control_flow/parser_spec.cr` covers its parsing —
  but no
  spec anywhere actually runs a `case` statement through `eval()` and
  checks the result. Not reported as broken, since nothing points at
  a specific bug the way the two precedents above did before they were
  found — just unverified, and worth a pass to either confirm it's
  fine or catch whatever it turns out not to handle.

### Error reporting

Runtime diagnostic carets — same underlying gap as originally filed
here — were promoted to `Must Fix` 2026-08-05; see that entry above for
current status.

- **U008–U015 are decided but not enforced.** Filed 2026-08-05 in two
  sessions (U008–U011, then U012–U015 added the same day after the
  mruby full-repo sweep) — see `UNSUPPORTED.md` for all eight entries
  (`private`/`protected`/`public`, `Struct.new`, `super` across
  multiple `rescue`, `$globals`, numbered block params, endless `def`,
  `class << self`, `undef`/method-added hooks). Each currently falls
  through to a generic undefined-name/undefined-method/parse error
  rather than naming the construct — the same gap U001–U004 had before
  their 2026-07-27/28 enforcement pass, and the exact failure shape
  `UNSUPPORTED.md`'s own design principle warns against. Follows the
  established decide-first-enforce-second pattern rather than waiting
  on enforcement to write the entries (see U007's own precedent —
  already partially enforced/partially not, same file). Most of the
  eight are a lookup-after-resolution-fails check, same mechanism as
  U005–U007 (`dispatch_call`/constant resolution, `vm.cr`); U012–U015
  are parse-time rather than resolution-time (numbered params/`undef`/
  `class << self`/endless-`def` all fail differently at the parser
  today, not via name lookup) — worth confirming the right enforcement
  point per item rather than assuming all eight share one mechanism.

- **U007's reflection exclusion is a category, not a list, so only
  `ObjectSpace` is enforced.** Added 2026-07-29 while enforcing U005–U007.
  `UNSUPPORTED.md`'s U007 entry describes "arbitrary FFI,
  `ObjectSpace`-style introspection, and similar" — a shape rather than an
  enumerated set. `ObjectSpace` could be enforced because it is named;
  everything else reflective (`binding`, `methods`, `instance_variables`,
  `instance_variable_get`, and so on) still reports as an ordinary
  undefined name.

  Deliberately not enumerated during that work: deciding which names are
  permanently excluded is a scope decision, and making it while writing
  the enforcement would have settled it by implementation rather than by
  choice. The same applies to `class_eval`/`module_eval`/`instance_exec`
  under U006 — the same hazard as `eval`, but not currently declared.

  Worth a short scoping conversation to settle both lists, after which
  enforcement is a one-line table addition each.


Quality-of-diagnostic gaps in the `Diagnostic`/`ErrorCatalog` system
(see [ERRORS.md](./ERRORS.md)). None affect correctness — every one is
"the error is right, but says less than it could."

- **`@def_depth` counts nesting but doesn't record what the enclosing
  scope was, so U004 can't name it.** Added 2026-07-28 while migrating
  U004 to a diagnostic. The guard in `Compiler#compile_def` fires on
  `@def_depth > 0`, which is enough to know a `def` is nested inside
  *something* deferred but not whether that something was a `def` or a
  lambda, nor its name. The message therefore says "inside another
  method's body" generically, where it could say "inside method
  `foo`" and point a secondary span at `foo`'s own definition —
  materially more useful when the two are far apart in a long file, or
  when the nesting was accidental.

  The fix is to make `@def_depth` a small stack of
  `{kind, name, line, column}` rather than an `Int32`, threaded
  through `compile_proc` the same way the counter already is. Depth
  then becomes the stack's size, so the existing guard condition is
  unchanged. Deliberately deferred when U004 was migrated: it turns a
  counter into a data structure across every `compile_proc` call site,
  which is a wider change than the migration it would have ridden
  along inside.

  Would also give U004 its first real use of a secondary span, which
  nothing exercises yet.

### Object model

- **`Class#inherited` hook not implemented.** Found 2026-08-05 in the
  mruby full-repo sweep (`test/t/class.rb`). Real Ruby calls
  `self.inherited(subclass)` automatically the instant a class is
  subclassed, before the subclass body runs — there's no way to
  reconstruct this after the fact (by the time you'd poll for
  subclasses you'd need to already know their names). Distinct in kind
  from `class << self` (below, WONTFIX) — that's alternate syntax for
  something already expressible via `def self.x`; this is a real
  capability with no equivalent already-supported spelling. Primary
  use is registry/discovery patterns (a base class automatically
  tracking every class that inherits from it — plugin systems, ORMs,
  test-case discovery) without a separate manual-registration call in
  each subclass — plausible for an agent building a small plugin or
  multi-behavior dispatch system of its own. Considered against
  monkey-patching concerns during triage (2026-08-05 chat) and judged
  distinct: the hook's pragmatic use (registry-on-subclass) doesn't
  require or enable monkey-patching, which stays excluded regardless.
  Not yet traced to a starting file/method — likely lands wherever
  `ClassNode`/`class Foo < Bar` compiles the superclass link
  (`compiler.cr`), triggering a call to the superclass's own
  `inherited` if defined, same shape as other hook-style dispatch.

Per-instance singleton methods became a deliberate non-goal 2026-07-27
(see [UNSUPPORTED.md](./UNSUPPORTED.md), U004). Implicit-`self`
privacy/visibility (`private`/`public`/`protected`) became a deliberate
non-goal 2026-08-05 (see UNSUPPORTED.md, U008). `Class.new(kwargs)` →
`initialize` binding was promoted to `Must Fix` 2026-08-05; see that
entry above for current status.


### Data & builtin types

- **`Array`/`Hash` as a `Hash` key hashes by reference, not content.**
  `Value` has no custom `hash(hasher)` override, so a `Hash(Value, Value)`
  key lookup relies on Crystal's auto-generated struct hash — fine for
  `Nil`/`Bool`/`Int64`/`Float64`/`String`/`Sym` (all of which Crystal
  hashes consistently, INCLUDING cross-type for numerics: `5.hash ==
  5.0.hash` when `5 == 5.0`, confirmed by `hash_spec.cr`'s own passing
  regression test, not assumed), but an `Array` or `Hash` used AS a key
  hashes by Crystal's default reference identity, not by the
  elements/pairs it contains — so `{[1,2] => "a"}[[1,2]]` (a different
  `Array` object with equal contents) would NOT find `"a"`, even though
  `ValueOps.equal?([1,2], [1,2])` is `true`. Same root cause as the note
  in `ValueOps.equal?`'s own comment (`value_ops.cr`) — noted here too
  since it's the kind of gap easy to rediscover the hard way inside a
  `Hash`-keyed-by-container script. Fixing this properly would mean
  giving `Value` a real custom `hash(hasher)` for the `array?`/`hash?`
  cases specifically (hashing by contents, recursively) — a deliberate,
  scoped change, not a quick patch, and only matters for the (currently
  rare) case of a container used as a hash key.
- **String repetition** (`"ab" * 3`). `ValueOps.op` (the method backing
  `*`, see `value_ops.cr`) has real `Integer`/`Float` cases but no
  `String` one — `+`, `==`, and `<`/`<=`/`>`/`>=` all DO already work for
  strings at the opcode level (see `ValueOps.add`/`.equal?`/`.compare`),
  so this is narrowly about `*` specifically. Noticed while bootstrapping
  the `String` builtin class (Phase 4a of base types); out of scope there
  since that work only wires up native METHODS, not opcodes.

### IFC / risk-flow

Carried forward from the original 2026-07-14 handoff — the oldest items,
undesigned rather than merely unimplemented, more product-shaped than
bug-shaped. Worth a dedicated design pass rather than picking off
individually.

- **No structured audit-trail export beyond `RiskFlowLog` itself.**
  Nothing turns a `RiskFlowLog` into a saved/replayable session record.
- **The approval cache** (avoid re-prompting for an already-approved
  origin→sink flow within one script run) — still not designed.
- **Eager vs. lazy ambiguous-priority policy validation** for
  `RiskFlowPolicy` — still not decided.

### Standard library surface

- **`catch`/`throw` (Kernel non-local jump, tagged block).** Found
  2026-08-05 in the mruby full-repo sweep — mruby packages this as an
  optional gem (`mruby-catch`) rather than core language, which is the
  right call for Adjutant too: `catch`/`throw` are `Kernel` methods in
  real Ruby, not keywords, so nothing about the language grammar needs
  to change. Buildable as a native module on top of the exception
  machinery already built for `raise`/`rescue` (a tagged non-local
  jump is structurally close to a targeted raise) rather than needing
  new opcodes — natural fit for the core-API-library work rather than
  a standalone language-layer item. Filed here rather than under a
  language-gap group for that reason.
- **No native File IO/HTTP module — really a scoping question, not a
  missing-feature bug.** Only `SampleModule`'s simulated I/O exists
  today. Reframed 2026-07-27 (previously filed as a plain missing-
  feature item, alongside the IFC items above): the actual open
  question is which parts of a File/HTTP-shaped stdlib surface are
  worth exposing at all, given every native method is a deliberate
  IFC-relevant decision (provenance, sensitivity, risk-flow policy
  implications — see `declare_sensitivity` and the IFC design arc), not
  just a Ruby-compatibility checkbox. Needs its own design pass to
  decide the actual surface (which methods, what they're allowed to
  touch, how they interact with `RiskFlowPolicy`) before implementation
  is meaningful — carried forward from the original 2026-07-14 handoff
  as "no IO," refiled here now that the real blocker (undecided scope,
  not undecided design mechanics) is clearer.

### Long-standing language gaps

One bundled entry, unchanged since the original 2026-07-14 handoff and
not touched by any session since — genuinely a backlog rather than
active work. Worth splitting into individual entries if any one becomes
a priority; currently untriaged relative to each other.

Two items originally listed here left this bundle 2026-08-05: multiple
`rescue` clauses (promoted to `Must Fix`, see above) and `super` across
multiple `rescue` clauses / `$globals` (moved to `UNSUPPORTED.md` as
U010/U011 — see that file; `Struct.new`, U009 in the same batch, was
never listed in this bundle and is noted separately in the gap-survey
chat history).

- assignment-as-real-expression (`c = b = 5` doesn't parse)
- `include`/mixins — real gap, but the specific case that most often
  motivates it (sharing comparison behavior via `Comparable`) is now
  covered by the `<=>` hook (implemented 2026-08-06 — see git history,
  no longer a `Must Fix` entry); what's left is general code-sharing,
  which reopens some of the same static-resolvability tension the
  `send`/`eval` exclusions (U005/U006) exist to avoid — worth its own
  scoping pass before promoting, not a drop-in fix. Noted 2026-08-05.
- heredocs/`%w[]` literals
- multi-level closures
- `Range` for non-`Integer`/non-`succ`-having bound types beyond what's
  already generic
- a real `Numeric` ancestor class in the `RubyClass` hierarchy (so
  `5.is_a?(Numeric)` etc. would work) — narrowed 2026-08-06: `<=>`
  itself now works for `Integer`/`Float`/`String` (`ValueOps.spaceship`,
  `exec_builtin`'s `"<=>"` case), which was this bullet's original
  practical motivation and is no longer the gap; what's left is
  specifically the class-hierarchy piece, a smaller and more optional
  want than before.
- `respond_to?`'s blind spot (`x.respond_to?(:to_s)` is `false` even
  though `x.to_s` works)

## Deliberate non-goals

Constructs and design decisions that are permanently out of scope no
longer live here — they moved to [UNSUPPORTED.md](./UNSUPPORTED.md) on
2026-07-28 (the section was called `Won't Support`, and `Won't Fix` before
that). They were extracted because they are a normative reference rather
than a work queue: nothing in that list is ever "done," and it accounted
for nearly half of this file while describing work that will never happen.

If you are deciding whether something belongs there or here: an item in
this file is expected to leave it, by being fixed. An entry in
`UNSUPPORTED.md` leaves only if the reasoning that closed the door stops
holding, which is a design conversation in its own right.
