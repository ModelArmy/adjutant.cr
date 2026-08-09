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

- **Native methods have no way to declare or receive `kwargs` at
  all.** Found 2026-08-08 while threading kwargs through
  `Class.new(name: ...)` for a script-defined `initialize` (that item
  has since shipped and been removed from this file — see git
  history/`DEVELOPMENT.md`'s "Argument binding" section). `NativeCallable` only ever receives
  `args : Array(Value)` — there's no `Param` list, and so no
  `kwarg?`/name-matching machinery, for anything implemented in
  Crystal rather than compiled from `def...end`. `VM#call_native`
  reflects this honestly today (`reject_kwargs!` fires unconditionally
  on any native call, `.new` included when it resolves to a native
  singleton method — see `VM#construct`'s native-`.new` branch), but
  that's a real ceiling, not just an unimplemented nicety: the
  upcoming core-API-library work is exactly the kind of surface where
  a Ruby-compatible native method (`Config.new(retries:, timeout:)`
  backed by Crystal rather than script, or any other native method
  wanting an options-hash-shaped call) would need this and can't get
  it today. Not yet traced to a starting file/method — needs some
  `NativeCallable`-side way to declare accepted keyword names (an
  analogue to `Param#kwarg?`/`Param#default`, but for a Crystal
  function signature rather than an AST), and `call_native` taught to
  check against it instead of rejecting outright. Worth deferring
  until a concrete native API actually needs it, so the shape isn't
  designed in the abstract — but flagged now so it isn't rediscovered
  cold mid-core-API-library work.

## Will Fix

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

Grouped by capability so adjacent work is easy to spot — within a group,
still roughly ordered by how cheap/independent the fix is.

### Parser / lexer gaps

Small, mechanical, independent of each other — good candidates for quick
wins.

- **Assignment isn't a real expression — promoted 2026-08-08 out of
  the "Long-standing language gaps" bundle below, where it had sat as
  a single untriaged line (`assignment-as-real-expression`) since the
  original 2026-07-14 handoff.** Two concrete manifestations, both
  the SAME root cause, found on different dates:
  - **Chained assignment** (`c = b = 5` doesn't parse) — the original
    2026-07-14 finding.
  - **Parenthesized/nested assignment** (`x = (w.attr = 5)` doesn't
    parse either) — found 2026-08-08 while spec'ing the new
    `AttrAssign` work (`assignment/vm_spec.cr`): a test wanted to
    capture an attribute-assignment's own expression VALUE the
    natural way, `result = (w.value = 5)`, and hit `P001` ("expected
    `)`, found `=`") instead. Reworked that spec to check the same
    contract via `eval`'s own return value instead of depending on
    this — see that spec's own comment for why it doesn't need to
    wait on this fix.

  Root cause, confirmed by tracing both: assignment is built ONLY at
  the STATEMENT level. `Parser#parse_expr_statement` calls
  `parse_expression(0)` for a bare expression, THEN checks for `=`/
  compound-assign tokens itself and calls `maybe_assignment` — but
  `parse_expression`'s own precedence chain never invokes
  `maybe_assignment` anywhere inside it. So an assignment can only
  ever be the OUTERMOST node of a top-level statement; anything that
  parses a sub-expression via `parse_expression` (a parenthesized
  group in `parse_primary`, an argument in a call, either side of a
  chained `=`, ...) structurally cannot contain one. A real fix
  likely means giving `=` its own (low-precedence, right-associative,
  matching real Ruby) level INSIDE `parse_expression`'s own chain,
  rather than handling it as a bolted-on statement-level afterthought
  the way `maybe_assignment` currently does — worth scoping BOTH
  manifestations together, since whatever mechanism fixes one fixes
  the other for free; they're one gap, not two.

- **`obj.attr += 1` / `obj.attr ||= x` / `obj.attr &&= x`** — compound
  and conditional assignment through an attribute-setter call. Found
  2026-08-08 landing plain `recv.attr = value` (the new `AttrAssign`
  node, ast.cr/parser.cr/compiler.cr/vm.cr — see `DEVELOPMENT.md`'s
  Parser section for the full trace). `Parser#maybe_assignment` only
  builds `AttrAssign` for its plain-`=` branch; the `PlusEq`/`MinusEq`/
  .../`OrAssign`/`AndAssign` branches immediately below still build an
  ordinary `OpAssign`/`CondAssign` with the `Call` as `target`, which
  `Compiler#emit_store`'s generic per-target-kind dispatch has no case
  for — falls to the same `C001` ("cannot assign to a method call") it
  always has. Not simply a matter of adding an `emit_store` `Call`
  case the way `Index`'s case already exists: `OpAssign`/`CondAssign`
  both read the target ONCE (`compile_node(node.target)`, at the very
  top of `compile_op_assign`/`compile_cond_assign`) before computing
  anything — for a `Call` target that means calling the GETTER — and
  then need to call the SETTER afterward with the combined result,
  which means the receiver expression needs evaluating exactly once
  and reusing (not recompiling) for both the getter and setter calls,
  the same single-evaluation requirement `AttrAssign` was built to
  satisfy for plain `=`. Needs a dedicated desugar/AST shape of its
  own (something that computes the receiver once, calls the getter
  off a stack-held copy, computes the op, then calls the setter off
  the SAME copy) — a genuinely different shape from `AttrAssign`, not
  a small extension to it.

- **`compile_case`'s missing receiver bit on its `"==="` `Op::Call`.**
  Found 2026-08-06 while implementing the (now-done) `Class#===`/
  `Range#===` fix — same shape of bug `compile_spaceship` had for
  `<=>`, but NOT the same cheap fix: real Ruby's `case/when` calls
  `pattern === subject` (pattern is the receiver), while
  `compile_case` currently pushes subject-then-pattern, the reverse
  of what a receiver-based call needs (the receiver must be pushed
  first, matching `compile_call`'s own convention) — so a real fix
  needs a new `Swap` opcode or a synthetic local to hold the subject
  across the `when` chain, not a one-line flag addition like
  `compile_spaceship`'s was.

  Deliberately left unfixed when the `Class`/`Range` item shipped, not
  an oversight: nothing today can register a real `"==="` for this bit
  to matter to — no script class can (`"==="` gained a real lexer
  token 2026-08-07, specifically so `def ===` reaches `U017`'s
  rejection rather than becoming definable; see `UNSUPPORTED.md`), and
  `Class#===`/`Range#===` are implemented directly in `exec_builtin`,
  not as `native_methods` entries, specifically so they don't depend
  on this bit either. Worth reopening if either of those ever changes
  — a future native module registering its own `"==="`
  `native_methods` entry would silently never be reached without this
  fix, the exact shape of bug this whole family (`compile_spaceship`,
  `compile_case`) keeps producing.

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
as originally filed here — was promoted to `Must Fix` 2026-08-05 and
shipped 2026-08-08 (`Parser#parse_hash_key`/`#label_follows?`,
parser.cr). See DEVELOPMENT.md's hash-literal note for the final
shape.

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

Empty as of 2026-08-06 — `case`/`when` was this category's one
remaining entry (found earlier the same day, no VM-level test anywhere in the
repo despite a real, seemingly complete `compile_case`), and this
session's `===` work closed it properly: `control_flow/vm_spec.cr` now
covers literal matching, `else` fallthrough, `Class#===`, `Range#===`
(inclusive and exclusive), and the plain-`==` fallback. Confirms the
category's own framing was right to take seriously — this wasn't
"probably fine," it was hiding the exact `===` fallback bug the
adjacent `Must Fix` item existed to fix, undiscovered specifically
because nothing had ever run it.

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
`initialize` binding was promoted to `Must Fix` 2026-08-05 and has
since shipped (see git history/`DEVELOPMENT.md`'s "Argument binding"
section).


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

- **`dup`/`clone` on a builtin-kind receiver** (Integer, String, Array,
  Hash, Symbol, true/false/nil, ...) raise `NoMethodError` rather than
  copying. Found 2026-08-08 landing `dup`/`clone` for RubyObject
  receivers (`exec_builtin`'s new `"dup", "clone"` case, vm.cr) — a
  RubyObject copy is a clean shallow-`ivars`-copy question, but a
  builtin receiver isn't: real Ruby returns the receiver itself for a
  true immediate (Integer, Symbol, true/false/nil) but an independent
  copy for String/Array/Hash, and Adjutant's `Value` model can't yet
  tell two separately-boxed instances of the same collection apart at
  all — the exact identity gap the entry above and `equal?`'s own
  comment (vm.cr's `exec_builtin`) already document. Matching only the
  immediate half of that split would be actively wrong for the other
  half, so both were left raising rather than half-implemented.
  Depends on (or at least belongs right alongside) resolving that
  underlying content-vs-reference identity question, not a fix of its
  own.

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

Three items originally listed here have left this bundle: multiple
`rescue` clauses (promoted to `Must Fix`, 2026-08-05, see above);
`super` across multiple `rescue` clauses / `$globals` (moved to
`UNSUPPORTED.md` as U010/U011 — see that file; `Struct.new`, U009 in
the same batch, was never listed in this bundle and is noted
separately in the gap-survey chat history); and
assignment-as-real-expression (promoted to its own entry under
"Parser / lexer gaps" above, 2026-08-08, once a second manifestation
made it concrete enough to scope).

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
