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

- **Default parameter values, splat collection, and keyword arguments
  don't actually work at runtime — only required positional params do.**
  Found 2026-07-27 while auditing `SCOPE.md`'s `Won't Support` list for
  whether each item fails loudly (it doesn't directly belong to that
  list — this is a correctness bug in a feature meant to work, not a
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

  Distinct from `&blk`-param capture (`Won't Support`, now actively
  rejected at compile time as of this same session) — `&blk` is a
  deliberate cut; this is a bug in functionality that's supposed to
  work and currently silently doesn't. Fixing this properly means
  giving `VM#call_script_proc` (or an equivalent prologue emitted by
  the compiler) real per-param logic: evaluate `default` when a slot
  has no matching positional arg, collect a `splat?` param from
  whatever positional args remain after fixed params are satisfied,
  and extract `kwarg?` params from keyword-style call arguments once
  the call-site parser gap above is also closed. Three sub-problems,
  likely one coordinated fix given they share the same binding
  mechanism.

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

### Object model

The privacy/visibility model below is the one open item in this group —
per-instance singleton methods, previously listed here, moved to
`Won't Support` 2026-07-27 (see below).

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

## Won't Support

Deliberately out of scope, with the reasoning that closed the door —
revisit only if the stated reason no longer holds.

- **`&blk`-param capture / block literals as first-class `Proc` values.**
  Decided 2026-07-18 alongside Piece C's design: only `Lambda`-node output
  (`->(){}` — Adjutant has no Kernel `lambda { }` function) becomes a
  real `Proc` object. A `{ }`/`do...end`
  block passed to a call stays consumable only via implicit `yield`
  inside that call — it's never bound to a named parameter, never
  returned, never stored. Real Ruby supports `def foo(&blk)`; Adjutant
  deliberately doesn't (yet) — narrowing the subset rather than widening
  it, kept simple until something depends on it. Revisit as a new,
  separate item if a real script needs to hold and defer-call a block.
  **Actively blocked as of 2026-07-27:** until then, `def foo(&blk)`
  compiled fine and silently bound `blk` to `nil` — a script only
  discovered the gap if/when it tried to actually use `blk` (`blk.call`
  raised a generic "undefined method or variable: call", with no hint
  that `&blk` itself was the real problem). Now rejected immediately at
  compile time, with a message naming the construct — see `compile_def`
  in `compiler.cr`. Verified via `compiler_spec.cr`'s "rejects &blk
  param capture at compile time" (plus a sibling regression check
  confirming ordinary `yield`, a separate mechanism, is untouched by the
  guard) — moved there from a `spec/scripts/` probe script 2026-07-27,
  since `test_runner`'s assert framework can't intercept a
  `CompileError`/`ParseError` at all (both abort the whole file before
  any assertion machinery loads; only a spec using `expect_raises`
  directly can assert on one). The raised message itself deliberately
  does NOT reference `SCOPE.md` or any other file in this repo — it's
  end-user/LLM-facing, and a repo-internal doc path means nothing to
  either audience; it states only that the construct isn't supported.
- **`Class.new`/`Module.new`.** Explicit cut from the Object/Class/Module
  design conversation (2026-07-14 arc) — this bootstrap only makes
  `Class`/`Module` exist as real `RubyClass`es for `.class`/`is_a?`/
  `superclass` to work correctly; not meant to be instantiable from
  script. **Actively blocked as of 2026-07-27:** until then, nothing
  actually enforced this — `Class.new`/`Module.new` fell through to the
  generic `construct_object` path and silently succeeded, producing a
  bare, non-functional object (no name, no ability to define methods on
  it meaningfully). `RubyClass` gained an `uninstantiable?` flag, set
  for `Class`/`Module` specifically at bootstrap (see
  `Interpreter#bootstrap_core_hierarchy`), checked by `VM#construct`,
  which now raises a clear error instead. Verified via
  `spec/scripts/class_module_new.rb`.
- **Class/module reopening (`class Foo; end` written a second time to
  extend it — real Ruby's monkey-patching mechanism).** Decided
  2026-07-18 alongside the `Op::SetConstant` reassignment hardening (see
  `Must Fix` history): today this silently creates a brand-new,
  disconnected `RubyClass` and discards the first body entirely
  (`Op::MakeClass` never checks for an existing same-name class) — a
  real, separate bug, now converted into a loud `Op::SetConstant`
  redefinition error by that hardening rather than fixed properly (which
  would mean `Op::MakeClass` detecting and reusing an existing class).
  **Confirmed concretely by the person, 2026-07-18:** before the
  `Op::SetConstant` guard existed, reopening a BUILTIN specifically —
  `class String; def hello; "hello"; end; end` — silently broke every
  native `String` method (`.upcase` started raising undefined-method)
  once the constant was reassigned to the fresh, disconnected class,
  since the native methods only ever lived on the original, now-
  unreachable one. This is what confirmed a same-shaped existing spec
  (`singleton_methods_spec.cr`'s "a native singleton new still works
  alongside script singleton methods on the same class") had always
  been silently invalid — it only exercised `.new` plus one script
  method, narrow enough to never surface the breakage; removed outright
  rather than kept as a documented gap, since the pattern it tested
  (script-side `class Foo; end` extending an already-existing,
  host-registered class) isn't coming back — see below.
  Deliberately not building real reopening support: Adjutant's constants
  (including class/module names) are now enforced assign-once, and
  reopening is exactly a second assignment to the same constant — so
  supporting it would mean carving out a special exemption from that
  rule specifically for classes/modules, undermining the whole reason
  the rule exists (constant-valued things, notably `Lambda`s used as
  call arguments — see Piece D — being staticaly resolvable specifically
  BECAUSE a constant can't quietly become something else later).
  Adjutant scripts are LLM-generated, typically ephemeral/narrow in
  scope even when reused, so the case for real monkey-patching support
  is weak; failing loudly on an attempt is strictly better than the
  current silent data loss, and staying without it keeps Adjutant a
  proper subset of Ruby regardless (declining a feature, not adding
  divergent behavior). `Class.new`/`Module.new` above is the same
  family of cut for the same underlying reason.
- **Defining a method (`def` or `def self.foo`) nested inside another
  method's own body — runtime-conditional method definition.** This
  entry started narrower (2026-07-27, moved here from `Will Fix` as "no
  true per-instance singleton methods on `RubyObject`") and was
  generalized twice in the same session as the real shape of the
  problem became clearer — worth reading in sequence, since each step
  corrected something about the step before it, not just narrowed scope:

  1. **Original framing:** `Op::DefSingleton` (`def self.foo` when
     `self` is a `RubyObject`, not a `RubyClass`) targets the
     receiver's own *class* instead of the receiver itself. Believed to
     mean the method "leaks" onto every instance of that class.
  2. **Corrected via `spec/scripts/singleton_instance_methods.rb`
     (now moved into `compiler_spec.cr`, see below):** that's wrong —
     `Op::DefSingleton` writes into the class's SINGLETON table, which
     only a `RubyClass`-receiver call (`A.foo`) ever consults, never an
     instance call (`a.foo`). So `class A; def test; def self.hello;
     end; end; end` doesn't leak to siblings — it creates a
     class-level method invisible to `a`, `b`, or any instance,
     reachable only as `A.hello`. Fixed at the time with a runtime
     guard in `Op::DefSingleton`, comparing the receiver against
     `main` specifically.
  3. **Generalized again, same session, prompted by the person's own
     follow-up test script:** that runtime guard only ever covered the
     `def self.foo` shape. A PLAIN `def nested` (no `self.`), nested
     the exact same way inside `test`, hits `Op::DefMethod` instead —
     never guarded at all — and writes directly into the class's
     ORDINARY instance method table. Confirmed concretely: `x.test`
     (where `test` contains a nested `def nested`) made `nested`
     callable on `x`, on a second pre-existing instance `y`, AND on
     instances constructed after `test` ran — a real leak to every
     instance, this time genuinely, not the misdiagnosis from step 1.
     This proved the real boundary was never "singleton vs instance
     method" or "which opcode" at all — it's whether a `def` executes
     exactly once, synchronously, as part of establishing the class
     (top level, or directly inside a class/module body) versus later,
     conditionally, as part of calling some other already-defined
     method. Both `Op::DefMethod` and `Op::DefSingleton` need the same
     answer to that question, not two different mechanisms.

  **Actively blocked as of 2026-07-27, final version:** moved out of
  `vm.cr` entirely and into `Compiler#compile_def` as a COMPILE-time
  check — `@def_depth`, incremented for `def` and lambda bodies
  (genuinely deferred/callable-later contexts), propagated unchanged
  through block bodies (which can only run synchronously via `yield` in
  Adjutant, never stored — see the `&blk` entry above), threaded through
  `compile_proc` since a nested proc body compiles via a brand-new
  `Compiler` instance that wouldn't otherwise see it. Any `def`/`def
  self.foo` node compiled while `@def_depth > 0` is rejected outright,
  regardless of receiver — strictly earlier and more complete than the
  runtime version it replaced (every case that one caught is, by
  construction, also caught by this one, since `self` can only BE a
  non-`main` `RubyObject` inside another method's own body to begin
  with). An ordinary top-level `def`, `def self.foo`, or a `def`
  directly inside a `class`/`module` body are all still completely
  unaffected. Verified via `compiler_spec.cr`'s nested-def specs
  (covering the `def self.foo` shape, the plain-`def` shape, a
  def-inside-a-lambda shape, and regression checks for both unaffected
  cases). Like the other entries in this section, the raised error text
  doesn't reference `SCOPE.md` or any repo-internal doc.

  Decided 2026-07-27, prompted by the person's own `irb` trace of real
  Ruby's actual per-instance singleton-method semantics: runtime-
  conditional method definition — an object's or a class's method set
  changing as a side effect of calling some unrelated method, rather
  than being fixed once the class is established — undermines the same
  property the class-reopening decision above protects: that an
  object's callable surface is knowable from its class alone, not from
  simulating execution. Same family of cut, same underlying reason, as
  class/module reopening and `Class.new`/`Module.new` above. This
  section is fully enforced as of 2026-07-27.
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
