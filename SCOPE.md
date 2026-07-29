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

- **Default parameter values, splat collection, and keyword arguments
  don't actually work at runtime — only required positional params do.**
  Found 2026-07-27 while auditing the deliberate-non-goals list (then
  `SCOPE.md`'s `Won't Support` section, now
  [UNSUPPORTED.md](./UNSUPPORTED.md)) for whether each item fails loudly
  (it doesn't belong to that list — this is a correctness bug in a feature meant to work, not a
  deliberate cut — but the audit is what surfaced it). `Param` (`ast.cr`)
  correctly parses and carries `default`, `splat?`, and `kwarg?` for
  every param shape (`parser_spec.cr` already covers all three at the
  parse level) — but NONE of those three are ever read anywhere in
  `compiler.cr` or `vm.cr`. Argument binding
  (`VM#call_script_proc`) is unconditional positional index-copy:
  ```
  args.each_with_index do |arg, i|
    frame.locals[i] = arg if i < frame.locals.size
  end
  ```
  No default-expression fallback when an arg is omitted, no splat
  collection of extra positional args into an array, no keyword
  extraction — a `kwarg?` param is bound exactly like an ordinary
  positional one (works only by accident, only when called
  positionally). Confirmed empirically (not just via static reading) by
  running `spec/scripts/default_params.rb` and
  `spec/scripts/splat_params.rb`:
  - `def greet(name = "world"); name; end; greet` → `nil`, not
    `"world"` — the default expression never gets evaluated as a
    fallback at all.
  - `def sum(*args); args; end; sum(1, 2, 3)` → `args` bound to plain
    `1` (whatever lands at that one positional slot), not `[1, 2, 3]`.
  - A method with an earlier required param and a later default param
    (`def add(a, b = 10); a + b; end; add(5)`) doesn't just return the
    wrong value — it can raise, since the unfilled slot stays `Value.
    nil_value` and arithmetic on `nil` fails (`cannot add 5 and`,
    itself a good example of the error-message-quality problem under
    discussion: `Value#to_s` writes nothing for `Nil`, so the message
    silently drops which operand was the problem).
  - Keyword-argument CALL syntax (`greet(name: "Ruby")`) doesn't even
    PARSE — `parse_call_args_and_block` has no `name:` handling at all,
    confirmed via `parser_spec.cr`'s "does not yet parse keyword-argument
    syntax at a call site" (`expected RParen, got Colon`). Keyword param
    DECLARATION at the def site (`def greet(name:)`) does parse and
    compile, and can still be called positionally today (see
    `spec/scripts/keyword_params_defsite.rb`) — but there's no way to
    actually invoke it AS a keyword argument, so real keyword-style
    calls are blocked twice over (parse failure at the call site, silent
    non-binding even if that parse gap were closed).

  Distinct from `&blk`-param capture ([UNSUPPORTED.md](./UNSUPPORTED.md),
  U001 — actively rejected at compile time as of that same session) —
  `&blk` is a deliberate cut; this is a bug in functionality that's supposed to
  work and currently silently doesn't. Fixing this properly means
  giving `VM#call_script_proc` (or an equivalent prologue emitted by
  the compiler) real per-param logic: evaluate `default` when a slot
  has no matching positional arg, collect a `splat?` param from
  whatever positional args remain after fixed params are satisfied,
  and extract `kwarg?` params from keyword-style call arguments once
  the call-site parser gap above is also closed. Three sub-problems,
  likely one coordinated fix given they share the same binding
  mechanism.

- **`send`/`method_missing`/`eval`/reflection are declared unsupported but
  almost certainly aren't enforced.** Added 2026-07-28, while extracting
  [UNSUPPORTED.md](./UNSUPPORTED.md) — U005 (dynamic dispatch by computed
  method name: `send`, `public_send`, `method_missing`, `define_method`),
  U006 (`eval`/`instance_eval`), and U007 (reflection into native
  internals: FFI, `ObjectSpace`-style introspection) have been documented
  exclusions since the risk-model design, but unlike U001–U004 nothing
  appears to reject them by name. The expectation — believed, not yet
  confirmed empirically — is that these names are simply undefined, so a
  script using one gets a generic undefined-method error that never says
  the construct is deliberately excluded and never will be.

  That is precisely the failure shape the 2026-07-27 audit removed from
  U001–U004: it doesn't silently do the wrong thing, but it does leave the
  reader (a human, or an LLM that generated the call) with no way to tell
  "this doesn't exist yet" apart from "this will never exist." These three
  are the *permanent* kind, so a misleading message here is worse than
  elsewhere — an LLM's natural next move on undefined-method is to retry
  with a variation, and every variation will fail the same way.

  Two steps, in order:
  1. **Verify.** Run a probe for each construct and record what actually
     happens today. Belongs in `spec/scripts/language/` if it fails at
     runtime, or in a `.cr` spec with `expect_raises` if it fails at parse
     or compile time — see the `test_runner` constraint noted against
     U001's enforcement history (a `ParseError`/`CompileError` aborts the
     whole script file before any assertion machinery loads, so
     `assert_raise` can never observe one).
  2. **Remediate** whatever isn't already loud, following the U001–U004
     pattern: reject as early as the construct is detectable, name the
     construct, and say nothing about this repo's internals in the
     message. `send` and friends are detectable at compile time from the
     literal `Call#method` name; `eval`/`instance_eval` likewise.

  Sequencing note: this is a natural first consumer of the `U`-code
  diagnostic work, since all three want the same message shape and none
  of them has a legacy message to preserve. Worth doing after that lands
  rather than writing messages twice.

## Will Fix

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

Grouped by capability so adjacent work is easy to spot — within a group,
still roughly ordered by how cheap/independent the fix is.

### Parser / lexer gaps

Small, mechanical, independent of each other — good candidates for quick
wins.

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
- **Symbol-shorthand hash literal syntax** (`{k: v}`).
  `Parser#parse_hash_or_block_brace` only ever calls
  `expect(TokenKind::HashRocket)` — there's no branch checking for a
  colon after a bare identifier key, so `{a: 1}` doesn't parse at all
  today; only `{"a" => 1}` (hash-rocket) does. Noticed while
  bootstrapping the `Hash` builtin class (Phase 4c of base types), which
  is otherwise unaffected — every `Hash` method works on however the
  hash `Value` was constructed. Small parser addition whenever it's
  worth doing.

### Error reporting

Quality-of-diagnostic gaps in the `Diagnostic`/`ErrorCatalog` system
(see [ERRORS.md](./ERRORS.md)). None affect correctness — every one is
"the error is right, but says less than it could."

- **No category for host-API misuse, so those errors have nowhere good
  to go.** Found 2026-07-28 while migrating internal invariants: a check
  like `Interpreter#invoke_proc` receiving a non-`Proc` looks like an
  internal type invariant, but `invoke_proc` is public host API, so an
  embedding host reaches it by passing the wrong `Value`. It can't be an
  `I` code, whose footer would tell an integrator to report their own bug
  upstream; it isn't a script fault either, so `R` fits badly. Left as an
  unmigrated plain message for now.

  Worth deciding once there are two or three such sites rather than one —
  candidates are a new letter (the reader's action is "fix your
  integration", genuinely distinct from the existing five) or folding
  them into `R` and accepting the imprecision.

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

The privacy/visibility model below is the one open item in this group —
per-instance singleton methods, previously listed here, became a
deliberate non-goal 2026-07-27 — see [UNSUPPORTED.md](./UNSUPPORTED.md),
U004, which generalised it to nested method definition of any shape.

- **No implicit-`self` privacy/visibility model.** Adjutant has no
  `private`/`public`/`protected` at all — a native function or top-level
  `def` (both land on `Object`) is reachable via an explicit receiver on
  any inheriting object (`Foo.new.puts_equivalent`), unlike real Ruby's
  Kernel methods, which are private. Found while fixing piece B (the
  root-scope work); see `root_scope_spec.cr`'s own test coverage of the
  current (permissive) behavior.

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

- assignment-as-real-expression (`c = b = 5` doesn't parse)
- `include`/mixins
- `super` across multiple `rescue` clauses per `begin`
- `$globals` (lexed as `GVar` but never consumed by the parser — see
  `DEVELOPMENT.md`'s scoping section)
- heredocs/`%w[]` literals
- multi-level closures
- `Range` for non-`Integer`/non-`succ`-having bound types beyond what's
  already generic
- `<=>` for `Integer`/`Float`, a shared `Numeric` ancestor
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
