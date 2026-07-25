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

- **Unary minus on a NEGATIVE-NUMERIC-LITERAL binds looser than postfix
  `.method`, when it should bind tighter for a literal specifically.**
  Found 2026-07-25 by the person while running mruby's
  `spec/scripts/mruby/float.rb` fixture (`-0.0.to_s` → `cannot negate
  0.0 (String)`, i.e. `to_s` ran first, THEN negation was attempted on
  its `String` result). Root cause: `Parser#parse_unary`'s
  `TokenKind::Minus` branch (`parser.cr`) does `Unary.new(op,
  parse_unary, l, c)` — recursing into `parse_unary` directly, whose own
  `else` branch is `parse_postfix(parse_primary)`. For `-0.0.to_s`, the
  recursive call parses `0.0.to_s` as a complete postfix chain FIRST
  (`Call(FloatLiteral(0.0), "to_s")`), and only then does the outer
  `Unary(Minus, ...)` wrap the whole thing — negating the call's
  result, not the literal before the call runs.

  Confirmed via Ruby core's own bug tracker (bugs.ruby-lang.org/issues/
  19583, closed as "not a bug," explicitly authoritative on this exact
  question) that this is NOT a general "unary minus should bind tighter
  than postfix" rule — that would be WRONG and would incorrectly change
  `-a.to_s` (`a` a variable) too, which real Ruby parses as `-(a.to_s)`,
  matching Adjutant's current (correct-for-that-case) behavior. The
  actual rule, quoting a Ruby core dev directly on that thread: "`-2`
  is a literal[;] `- 2` is a function call of `-@`[,] and `-@` doesn't
  have preference over function call." I.e. `-` immediately preceding a
  bare numeric literal token fuses into a single NEGATIVE-LITERAL node
  at parse time (not a `Unary` wrapping anything) — precedence doesn't
  even enter into it for that specific shape, since there's no separate
  unary-minus AST node at all once fused; postfix chaining then applies
  to that fused literal, giving `(-0.0).to_s` the correct grouping "for
  free." For every other unary-minus target (a variable, a call result,
  a parenthesized expression), today's `Unary`-wraps-postfix behavior
  is already correct and must NOT change.

  Design implication, not yet fully scoped: needs a check in
  `parse_unary`'s `TokenKind::Minus` branch — specifically, when the
  very next token is `TokenKind::Integer`/`TokenKind::Float` (i.e. the
  minus is immediately adjacent to a numeric literal, not some other
  expression), parse a fused negative-literal node (or equivalently,
  parse the literal and negate its VALUE at parse/compile time, then
  apply `parse_postfix` to THAT), rather than the general `Unary.new(op,
  parse_unary, ...)` path. Needs a real design conversation before
  implementation — in particular, whether "immediately adjacent" should
  be about token adjacency (no whitespace) or purely about "next token
  is a bare numeric literal" regardless of spacing (Ruby's own rule,
  per the bug thread, is about the token being a literal, not about
  whitespace — `- 2` with a space is EXPLICITLY called out as the
  function-call form, i.e. whitespace DOES matter to Ruby's own lexer
  here, unlike the `identifier [expr]` disambiguation fixed 2026-07-21,
  which turned out to NOT be whitespace-sensitive at all — these are
  two different rules and shouldn't be assumed to share a mechanism).
- **Unary `+` is entirely unsupported — parse error.** Found 2026-07-25
  by the person (`+1`, `+n` both fail: `parse error: ... unexpected
  token Plus ("+")`). Confirmed via Ruby's own precedence doc
  (docs.ruby-lang.org/en/3.3/syntax/precedence_rdoc.html) that unary
  `+` is a real, documented operator — same precedence TIER as `!` and
  `~` (the highest tier, above `**`, above unary `-`), explicitly
  listed as being "for `+1`" alongside unary `-`'s `-1`. Root cause:
  `Parser#parse_unary`'s `case current_kind` (`parser.cr`) has branches
  for `TokenKind::Bang`, `TokenKind::Minus`, `TokenKind::Tilde`,
  `TokenKind::KwNot` — no `TokenKind::Plus` branch at all, so a leading
  `+` falls through to `parse_primary` via the `else` branch, which
  doesn't expect to start on a `Plus` token.

  Confirmed via `compile_unary` (`compiler.cr`) that the VM/compiler
  side needs NO new opcode: its `case node.op` already has no
  `TokenKind::Plus` branch, so a `Unary(Plus, expr)` node would
  silently fall through and emit nothing beyond `compile_node(expr)` —
  i.e. the operand's value is left on the stack completely unchanged,
  which happens to BE the semantically correct behavior for numeric
  unary `+` (a documented no-op) purely as a side effect of the `case`
  having no matching branch, not by deliberate design. Likely fix is
  therefore parser-only: add a `TokenKind::Plus` branch to
  `parse_unary` mirroring the existing `Bang`/`Tilde` branches
  (`Unary.new(op, parse_unary, l, c)`) — no literal-fusion needed,
  unlike unary minus above, and no compiler change needed either, given
  the fallback-to-no-op behavior already matches what's wanted. Worth
  a small design check on whether `+` on a NON-numeric operand
  (`+"str"`, `+nil`) should raise (real Ruby: `+` on most non-Numeric
  types is a real `NoMethodError`, e.g. `String` has no `+@` — needs
  confirming Adjutant doesn't silently accept `+"str"` as a no-op where
  real Ruby would raise) before treating this as fully done.

## Will Fix

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

- **No true per-instance singleton methods on `RubyObject`.** `Op::DefSingleton`
  (`def self.foo` when `self` is a `RubyObject`, not a `RubyClass`)
  targets the receiver's own *class* instead — `RubyObject` has no
  singleton-method table of its own. Observably correct for the one case
  that matters in practice (`def self.foo` at top level, where `self` is
  always `main`, the one and only instance of `Object` a script typically
  has as `self` — see `Interpreter#main`), but means the method becomes
  callable as `Object.foo` (explicit receiver), not via a later BARE
  `foo` the way real Ruby's true per-object singleton method would be —
  found while writing specs for the 2026-07-16 root-scope work (piece
  B). See `DEVELOPMENT.md`'s "self at every level" section and
  `Op::DefSingleton`'s own comment in `vm.cr`. A real per-instance
  singleton-method table on `RubyObject` would close this properly, if
  it's ever worth the size of that change; genuinely narrow in practice
  since nothing else routinely calls `def self.foo` on an arbitrary
  (non-`main`) object today.
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
- **Symbol-shorthand hash literal syntax** (`{k: v}`).
  `Parser#parse_hash_or_block_brace` only ever calls
  `expect(TokenKind::HashRocket)` — there's no branch checking for a
  colon after a bare identifier key, so `{a: 1}` doesn't parse at all
  today; only `{"a" => 1}` (hash-rocket) does. Noticed while
  bootstrapping the `Hash` builtin class (Phase 4c of base types), which
  is otherwise unaffected — every `Hash` method works on however the
  hash `Value` was constructed. Small parser addition whenever it's
  worth doing.
- **Exponential float literals** (`1e10`, `1.5e-3`). `Lexer#scan_number`
  has no `e`/`E` exponent handling at all — `1e10` lexes as `Integer(1)`
  followed by a separate identifier `e10`, not a clean parse error.
  Noticed while bootstrapping the `Float` builtin class (Phase 3 of base
  types), which is otherwise unaffected — `Float` the class/its methods
  work fine on any float `Value`, however it was constructed (a plain
  decimal literal, `to_f`, division, ...); this is purely about the
  lexer not accepting one particular literal spelling. Small, mechanical
  fix whenever it's worth doing.
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
  already generic, `<=>` for
  `Integer`/`Float`, a shared `Numeric` ancestor, `respond_to?`'s blind
  spot (`x.respond_to?(:to_s)` is `false` even though `x.to_s` works).

## Won't Fix

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
- **`Class.new`/`Module.new`.** Explicit cut from the Object/Class/Module
  design conversation (2026-07-14 arc) — this bootstrap only makes
  `Class`/`Module` exist as real `RubyClass`es for `.class`/`is_a?`/
  `superclass` to work correctly; not meant to be instantiable from
  script.
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
