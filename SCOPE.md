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

**Reordered 2026-08-15**, on top of the existing dependency ordering: the
first five entries below are additionally sorted by how often ordinary,
idiomatic Ruby would reach for the construct and get silently wrong output
or a hard block — silent-wrong-answer entries lead, then everyday syntax
blocks, then idioms with a workaround. (A sixth, `Array#to_s`/`Hash#to_s`/
`Range#to_s`, led this list at the time of that reorder — it shipped
2026-08-16, see DEVELOPMENT.md's "to_s/inspect" writeup, and is removed
from here rather than left as a stale entry.) Two entries (`%w[]`/`%i[]`/
heredocs, `lambda`/`proc`) were promoted from `Will Fix` as part of the
same reordering pass — common enough in ordinary scripts that "not
currently blocking anything" no longer held. The remaining entries
(runtime carets, `respond_to?`) keep their prior relative order; they
weren't re-evaluated against the promoted two on this axis, just carried
forward.

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
  Related but distinct, found 2026-08-13 while triaging
  `spec/scripts/mruby/float.rb`: `Module#const_defined?` (the ordinary
  METHOD, e.g. `Object.const_defined?(:Float)`) also doesn't exist —
  it's a real gap in its own right, not just a symptom of `defined?`
  missing, since fixing the `defined?` keyword wouldn't give scripts
  `const_defined?` and vice versa (one's parser/keyword work, the
  other's an ordinary native method reachable via find_native_method).
  Worth scoping together since they serve the same defensive-
  programming purpose and a reader would reasonably expect both to
  land at once, but they're two separate pieces of work.

- **`respond_to?`'s blind spot returns a wrong answer, not an
  error.** Long-standing, untriaged since the original 2026-07-14
  handoff bundle — split out and reclassified 2026-08-10 while
  reviewing that bundle. `VM#exec_builtin`'s `"respond_to?"` case
  deliberately only checks user-defined and native method tables, the
  same three lookups `is_a?`/`.class` use — not `exec_builtin`'s own
  VM-level fallback cases (`to_s`, `class`, `is_a?`, ...). So
  `x.respond_to?(:to_s)` returns `false` even though `x.to_s` itself
  works — a silent wrong answer a script (or an LLM checking before
  calling) has no way to detect, not a clean failure. Already
  precisely diagnosed in the code's own comment at that case, which
  argues the near-universal fallback methods are rare enough to probe
  for that this was an acceptable tradeoff at the time — worth
  revisiting now that this file is being triaged for exactly this
  category of gap (silent incorrectness vs. missing feature). Fix
  shape: extend that case to also check a fixed list of the
  fallback-only names `exec_builtin` handles, rather than a full
  lookup-table rewrite.

- **`dup`/`clone` on a `RubyObject` SUBCLASS with real typed state
  outside `ivars` silently produces a wrong-typed object, then
  crashes on first use.** Found 2026-08-23 porting mruby-time's own
  `Time#initialize_copy` test (`spec/scripts/mruby/time.rb`) — not
  specific to `Time`. `exec_builtin`'s `"dup", "clone"` case (`vm.cr`)
  always allocates a plain `RubyObject.new(obj.rclass)` and shallow-
  copies `ivars`, correct for an ordinary class but wrong for any
  subclass carrying real fields outside `ivars` — `TimeObject`'s
  `@time` (`builtins/time.cr`), and equally `RegexpObject`'s `@regex`/
  `MatchDataObject`'s `@md` (`builtins/regexp.cr`), simply hadn't been
  caught yet (nothing in the existing suite calls `.dup`/`.clone` on a
  `Regexp`/`MatchData`). The clone comes back as a plain `RubyObject`,
  not the real subclass, so any method touching the actual typed field
  (`.year`, `.to_i`, a `Regexp` match call, ...) hits a raw Crystal
  cast failure (`Cast from Adjutant::RubyObject to
  Adjutant::TimeObject failed`) on first use — an ugly internal crash,
  not a clean Ruby-level error, and reachable in completely ordinary
  script usage (any `.dup`/`.clone` on one of these three types).
  Must Fix rather than Will Fix specifically because of that failure
  shape — silent wrong object followed by a confusing crash is exactly
  the "actively causing incorrect behavior in normal use" bar this
  section is for, not a missing-feature gap. Fix shape: give
  `RubyObject` (or each subclass) a virtual `#copy_state_into(other)`-
  style hook the `"dup"`/`"clone"` case calls after allocating the
  correctly-typed instance (needs a way to allocate the RIGHT Crystal
  class, not always a bare `RubyObject.new` — possibly a
  `RubyObject#shallow_copy : RubyObject` virtual method every subclass
  overrides, mirroring the pattern `RegexpObject`/`MatchDataObject`/
  `TimeObject` already use for their own typed-state constructors).

## Will Fix

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

Grouped by capability so adjacent work is easy to spot — within a group,
still roughly ordered by how cheap/independent the fix is.

### Parser / lexer gaps

Small, mechanical, independent of each other — good candidates for quick
wins.

- **No octal/hex/binary integer literal prefixes (`0o`/`0x`/`0b`) —
  and, worse, a LEADING-ZERO decimal like `0644` silently parses as
  plain decimal 644, not octal, with no error.** Found 2026-08-24
  writing a spec for `Legate::Stat#mode` (a real Unix permission bit
  value) — `s.mode == 0644` in a script silently compares against the
  wrong number, no parse error or warning at all, exactly the "ran,
  looked plausible, was wrong" bug shape worth staying alert for.
  Low practical urgency (permission-bit-style literals are rare
  outside exactly this kind of use), but worth fixing before any
  Legate verb that surfaces a real mode value (`Legate.mkdir`,
  anything touching `Stat#mode`) ships, since a script author's first
  instinct for "check the mode" would reach for exactly this syntax
  and get a silently wrong answer rather than a loud one.

- **Leading-dot line continuation for a method chain isn't supported**
  (`obj\n  .method\n  .method` — real Ruby 1.9+ syntax) — raises P002
  (`.` can't start an expression here) rather than parsing. Found
  2026-08-24 writing a multi-line `Legate::Stream` chain spec.
  Genuinely common, readable Ruby style for a chain of 3+ calls, and
  the kind of thing an LLM trained on real-world Ruby would reach for
  by default — worth fixing since a script author hitting this gets a
  parse error on ordinary-looking code, not silent wrongness, but
  still a real everyday-syntax gap.

- **`%W[]`/`%I[]` (interpolating word/symbol arrays) and `%q`/`%Q`/`%r`
  (the general delimited-literal forms) aren't supported — only plain
  `%w[]`/`%i[]` are.** Added 2026-08-19 alongside `%w[]`/`%i[]` itself
  going in for the first time (see `DEVELOPMENT.md`'s "The Lexer"
  writeup) — a deliberate scoping decision, not a later-discovered
  gap: `%w[]`/`%i[]` cover the common "word array"/"symbol array"
  idiom the Must Fix entry was written against, and the interpolating/
  general forms are rare enough in practice to leave for whoever wants
  a follow-up. Mechanically similar to add: `%W`/`%I` would need the
  word-splitting step to also watch for `#{...}` per word (closer to
  the heredoc interpolation path than the plain `%w` one), and `%q`/
  `%Q`/`%r` are just `'...'`/`"..."`/`/.../ ` with an arbitrary
  delimiter instead of the fixed one.

- **Heredocs support only ONE opener per physical line** — real Ruby
  allows stacking several (`foo(<<~A, <<~B)`), each consuming its own
  body block in order below the line, in sequence. Added 2026-08-19
  alongside `%w[]`/`%i[]`/heredocs going in for the first time (see
  `DEVELOPMENT.md`'s "The Lexer" writeup for the full mechanism) — a
  deliberate scoping decision at the time, not something later found
  broken: the lexer's eager single-opener resolution (`Lexer#scan_heredoc_opener`
  jumps straight to extracting/tokenizing the ONE pending heredoc's
  body the moment its opener is scanned) doesn't extend to a second
  opener appearing before the first's body has even been reached. A
  second opener on the same line currently just scans as ordinary
  (almost certainly nonsensical) `<<` tokens instead of failing
  loudly — worth tightening to a clean parse error at minimum, even
  before real multi-heredoc support lands. Rare enough in ordinary
  scripts (a single heredoc per line covers the vast majority of real
  usage) that it wasn't worth blocking the rest of the pickup on.

- **`break if cond; more_code` (or `next if cond; more_code`) mis-parses
  when break/next has a modifier `if`/`unless` immediately followed by
  more code on the same line (or block).** Found 2026-08-18 writing a
  spec for endless-range `#each`/`#step` (a range with no `break`
  never terminates, so the test needed one) — entirely unrelated to
  ranges themselves, a pre-existing bug just newly exercised.
  `parse_break` (parser.cr) grabs its own optional VALUE via
  `at_any?(Newline, Semi, EOF) ? nil : parse_expression(0)` before
  ever checking for a trailing `KwIf`/`KwUnless` modifier — but `if`
  is a valid expression-START token (`parse_primary` has its own
  `KwIf` case), so `break if n > 4; seen << n` parses `if n > 4; seen
  << n` whole as break's VALUE (a real if-expression, greedily
  consuming through to the enclosing block's own closing `}`/`end`
  looking for the if's own `end`) rather than stopping after `if n >
  4` and treating it as break's trailing modifier. Real Ruby's
  break/next argument grammar is more restricted than a full
  statement expression — it never starts with a bare `if`/`unless` —
  so the fix is narrowing `parse_break`'s own "does a value follow"
  check to also treat `KwIf`/`KwUnless` as "no value here, this is
  the modifier" makes the code AVAILABLE to the later `case
  current_kind when KwIf`/`KwUnless` branch already sitting right
  below it, unchanged. Confirmed via the same real-Ruby-first
  discipline as the rest of this session: `break if n > 4; seen << n`
  in `irb` unambiguously executes `seen << n` unless `n > 4`, never
  attempts to parse an if-expression as break's own value.

- **`&:symbol` proc-shorthand (`arr.map(&:length)`) isn't supported —
  `&` can't start an expression there at all (P002).** Found
  2026-08-26 writing a `Legate.lines` spec, reaching for
  `.map(&:length)` out of habit and hitting a hard parse error rather
  than a wrong answer. Common enough to matter: it's arguably THE most
  reached-for block shorthand in idiomatic Ruby, ahead even of a
  one-line `{ |x| x.foo }`, for exactly the "call one method on every
  element" shape that turns up constantly in `Legate::Stream` chains
  (`.select { }.map(&:foo)`-style code) — an LLM writing natural Ruby
  will reach for this by default, same "everyday syntax block" bar
  the leading-dot-chaining entry above was promoted on. Likely lands
  as sugar at the parser/AST level: `&:name` desugars to the same
  shape as a literal `{ |x| x.name }` block/`Proc` (real Ruby's
  `Symbol#to_proc`), so — depending how block-arg-passing is
  structured today — this may be closer to "recognize `&` followed by
  a Symbol literal and synthesize the equivalent block AST node" than
  new runtime machinery. Not yet traced to the exact parser callsite
  (wherever `&blockarg` is currently parsed at a call site) or
  confirmed whether `Proc`/`Symbol#to_proc` already exist as a target
  to desugar onto.
  `ensure` treatment `def` bodies just got?** Open question, not a
  confirmed gap — flagged 2026-08-10 when `def`'s own version shipped
  (see `DEVELOPMENT.md`'s "Method-body (implicit) rescue" section).
  Real Ruby's grammar treats `def`, `class`, `module`, and top-level
  program bodies uniformly as an implicit `begin` ("bodystmt") — so
  plausibly yes, `class Foo; risky; rescue; end` is valid Ruby too —
  but this hasn't actually been confirmed against real Ruby the way
  the `else`-without-`rescue`/duplicate-`else` behaviors were
  (`irb`-confirmed, see `parse_begin_else`'s own comments). If
  confirmed, the fix is likely the same shape `parse_def`'s just used
  — `parse_class`/`parse_module` (`parser.cr`) wrapping their own
  parsed body in a synthetic `BeginNode` via the same
  `parse_rescue_else_ensure` helper, reusing the identical
  compile/runtime path with no new compiler or VM work either.

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

- **U008, U009, U012–U015 are decided but not enforced; U011 was
  enforced 2026-08-14, no longer part of this list.** Filed 2026-08-05
  in two sessions (U008–U011, then U012–U015 added the same day after
  the mruby full-repo sweep) — see `UNSUPPORTED.md` for the six
  remaining entries (`private`/`protected`/`public`, `Struct.new`,
  numbered block params, endless `def`, `class << self`, `undef`/
  method-added hooks). `U010` (originally "`super` across multiple
  `rescue` clauses") was retired 2026-08-10, the same session `super`
  itself was built and shipped — the concern turned out not to be a
  real gap once `super` actually worked; see `UNSUPPORTED.md`'s U010
  entry. `U011` (`$globals`) was enforced 2026-08-14, prompted by
  deciding against building real Ruby's `$~`/`$1`-`$9`.. match
  globals for Regexp specifically (see `UNSUPPORTED.md`'s own U011
  entry for the full reasoning and what covers the gap instead) — a
  real `U011` diagnostic now fires at parse time by name rather than
  the generic fallback. Each of the remaining six currently falls
  through to a generic undefined-name/undefined-method/parse error
  rather than naming the construct — the same gap U001–U004 had
  before their 2026-07-27/28 enforcement pass, and the exact failure
  shape `UNSUPPORTED.md`'s own design principle warns against. Follows
  the established decide-first-enforce-second pattern rather than
  waiting on enforcement to write the entries (see U007's own
  precedent — already partially enforced/partially not, same file).
  Most of the six are a lookup-after-resolution-fails check, same
  mechanism as U005–U007 (`dispatch_call`/constant resolution,
  `vm.cr`); U012–U015 are parse-time rather than
  pattern rather than waiting on enforcement to write the entries (see
  U007's own precedent — already partially enforced/partially not,
  same file). Most of the seven are a lookup-after-resolution-fails
  check, same mechanism as U005–U007 (`dispatch_call`/constant
  resolution, `vm.cr`); U012–U015 are parse-time rather than
  resolution-time (numbered params/`undef`/`class << self`/endless-
  `def` all fail differently at the parser today, not via name
  lookup) — worth confirming the right enforcement point per item
  rather than assuming all seven share one mechanism.

- **No distinct `ZeroDivisionError` class — division by zero raises a
  plain `RuntimeError`.** Found 2026-08-10, writing test coverage for
  the method-body-rescue fix (`VM#error_raiser`/`VM#runtime_error`,
  `vm.cr`): `ValueOps`' arithmetic error path hardcodes
  `builtin_class_by_name("RuntimeError")`, unconditionally, regardless
  of what actually went wrong. Real Ruby raises `ZeroDivisionError` (a
  `StandardError` subclass) specifically for this — a script that
  writes `rescue ZeroDivisionError` expecting to catch it (reasonable,
  unsurprising Ruby) currently doesn't, silently: the rescue clause
  just never matches, and the error propagates uncaught instead of a
  clear "class doesn't exist" signal. Likely other arithmetic/type
  error paths through the same `on_error` callback have the identical
  gap (see `error_raiser`'s call sites in `value_ops.cr`) — worth
  auditing all of them together rather than fixing this one class in
  isolation.

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

- **Bracket indexing (`obj[i]`) on a custom/native-backed `RubyObject`
  now calls a NATIVE `[]` method for real — fixed 2026-08-14 — but a
  SCRIPT-DEFINED `[]` still can't be reached via `obj[i]` bracket
  syntax at all.** Found while wiring up `MatchData#[]`
  (`builtins/regexp.cr`): `exec_get_index`/`Op::GetIndex` was a fixed
  case statement covering only Array/Hash/String, with everything
  else falling straight to a silent `Value.nil_value` — a real
  silent-wrong-answer bug (the exact category worth staying alert
  for), not a raised error: `MatchData#[]` was registered correctly
  and simply never reached, no matter what it returned. Fixed via
  `exec_get_index_fallback` (`vm.cr`), which now calls a receiver's
  own native `[]` method via `call_native`, the same synchronous path
  `dispatch_call`'s ordinary receiver branch already uses for `.foo`
  calls.
  **Deliberately still open:** a SCRIPT-defined `[]` (`find_method`,
  not `find_native_method`) still isn't handled — `call_script_proc`
  pushes a new VM frame and relies on the normal `Op::Call`/`Op::Ret`
  dispatch loop to resume and deliver the result later, which
  `exec_get_index_fallback` (called synchronously from inside a
  single opcode's handler) has no mechanism to wait for. Low practical
  urgency today: `def [](i)` can't even be WRITTEN in script yet
  either way (see `UNSUPPORTED.md`'s U017 note — no combined `[]`
  lexer token, so `parse_def` trips on the stray `]` first) — so only
  native `[]` methods exist to reach at all right now, and this fix
  already covers every one of those. Worth a real fix (likely
  restructuring `Op::GetIndex` to push a frame and let the normal
  dispatch loop resume it, same shape as any other deferred script
  call) once/if `[]` becomes script-definable.
  `Op::SetIndex`/`exec_set_index` (the `obj[i] = v` write side) has
  the exact same shape of gap and was NOT touched by this fix — flagged
  here rather than silently assumed fixed alongside the read side.

- **`Op::Mul` (and `%`) still doesn't dispatch to a `RubyObject`'s
  own `*` — only `+`/`-`/`/` do now.** Added 2026-08-23 alongside a
  real `Time` builtin (`builtins/time.cr`) that needed `t + 60`/
  `t - 60` to work via ordinary infix syntax: `VM#exec_add`/`#exec_sub`
  (`vm.cr`) check whether the LEFT operand is a `RubyObject` with its
  own `+`/`-` (native or script) before falling through to
  `ValueOps`'s base-type handling — the same "left receiver's method
  wins when it has one" shape `<=>`-derived `<`/`<=`/`>`/`>=`/`==`
  already established. Widened same-day to `/` too (`VM#exec_div`) —
  `Legate::Path#/` (`legate/path.cr`, LEGATE.md §5.1) needed real
  infix `/` to work the moment Path's own spec was implemented, not
  just theoretically anticipated the way `*`/`%` still are.
  DEVELOPMENT.md's own "Some operators are overloaded across base
  types" section originally anticipated this whole gap for `-`/`*`/
  `/` and explicitly said to close each "if [something] does" need
  it; `Time` was that something for `+`/`-`, `Legate::Path` for `/`.
  `*`/`%` remain untouched — nothing needs them yet either — so this
  stays Will Fix rather than Must Fix; promote if a future type needs
  one.

- **No `Numeric` ancestor class in the `RubyClass` hierarchy, so
  `5.is_a?(Numeric)` fails rather than returning `true`.** Long-
  standing, untriaged since the original 2026-07-14 handoff bundle —
  reworded 2026-08-10 on review: the previous framing implied this
  silently returns a wrong answer, which isn't what actually happens.
  No class named `Numeric` is registered anywhere (`grep` confirms),
  so referencing it at all fails at constant resolution first — a
  clean, loud `R006` (undefined constant), not a silent `false`. Real
  gap, genuinely missing feature, but the loud-failure kind rather
  than the incorrect-in-normal-use kind. Narrowed 2026-08-06,
  separately from this rewording: `<=>` itself already works for
  `Integer`/`Float`/`String` (`ValueOps.spaceship`, `exec_builtin`'s
  `"<=>"` case), which was this item's original practical motivation
  and is no longer the gap — what's left is specifically the
  class-hierarchy piece.

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

- **Bare `new` (implicit `self`, no explicit receiver) doesn't
  dispatch inside a class method.** Found 2026-08-10, writing test
  coverage for the method-body-rescue fix — `def self.run; c = new;
  ...; end` raises `R008` ("undefined method or variable `new`"),
  while the exact same call written as `ClassName.new` works fine.
  `VM#dispatch_call`'s explicit-receiver branch has its own hardcoded
  `if recv.rclass? && name == "new"` special case for object
  construction — the implicit-self branch (self already IS the class,
  inside a class method) walks `find_singleton_method`/
  `find_native_singleton_method` normally instead, and `new` isn't
  actually registered in either of those tables; it only exists as
  that explicit-receiver special case. Not yet traced further than
  that — likely needs the same special-casing mirrored into the
  implicit-self branch, or `new` registered as a real native singleton
  method both branches would find the same way.

- **Top-level `extend` doesn't work — deliberately still excluded,
  not yet a real gap fix.** Bare top-level `include M` shipped
  2026-08-16 (see `DEVELOPMENT.md`'s "Bare `include` at the top level
  of a script" writeup for the full build-out) — this item is the
  narrower remainder, `extend` specifically, left out of that work on
  purpose rather than folded in. Confirmed against real `irb`:
  top-level `extend M` writes to a genuine PER-OBJECT singleton class
  belonging to `main` alone — `Object`'s own ancestors stay untouched,
  sibling `Object.new` instances are unaffected, and `Object.foo`
  doesn't pick up the extended method either (all three behaviors
  confirmed directly, not inferred). `RubyObject` has no storage for
  a per-instance singleton method table at all today — only
  `RubyClass` carries one (`singleton_methods`/`extended_modules`) —
  so `extend`'s existing mechanism (`RubyClass#extend_module`,
  consulted by `find_singleton_method`/`find_native_singleton_method`)
  has nowhere correct to target from `main`: writing into `Object`'s
  own `extended_modules` would make `Object.foo`-style calls work
  (wrong — real Ruby doesn't) while leaving bare calls at the top
  level unaffected (also wrong — that's the actual goal), the exact
  opposite of what's needed. Fix shape, if taken on: give `RubyObject`
  a genuinely new field (a `singleton_methods`/native counterpart,
  `nil` for every object except `main`), and a new lookup step in
  `dispatch_call`'s implicit-self `RubyObject` branch — checked BEFORE
  `cls.find_method`, matching the real `irb`-confirmed resolution
  order (`self.hello` found the extended method ahead of anything
  `Object` itself could offer) — gated on `self_val.same?(interp.main)`,
  the same restriction the shipped `include` fix already uses. Real,
  separate plumbing, not a small addition to the `include` mechanism —
  worth its own session rather than a quick follow-on.

Per-instance singleton methods became a deliberate non-goal 2026-07-27
(see [UNSUPPORTED.md](./UNSUPPORTED.md), U004). Implicit-`self`
privacy/visibility (`private`/`public`/`protected`) became a deliberate
non-goal 2026-08-05 (see UNSUPPORTED.md, U008) — this remains true for
visibility as a general, declarative feature; top-level `def` shipped
its own narrow, always-on private treatment 2026-08-16, not a
reopening of that decision (see DEVELOPMENT.md's "Top-level `def` is
implicitly private" writeup for the distinction). `Class.new(kwargs)` →
`initialize` binding was promoted to `Must Fix` 2026-08-05 and has
since shipped (see git history/`DEVELOPMENT.md`'s "Argument binding"
section).


### Data & builtin types

- **`Array` has no `#count` at all** (`#length`/`#size` exist, `#count`
  doesn't — checked `array.cr` directly). Found 2026-08-24 writing a
  `Legate::Stream` spec that called `.to_a.count` out of habit. Real
  Ruby's `#count` is `#size`'s more common spelling in idiomatic code
  and also overloads to count matching elements (`#count { }` /
  `#count(x)`, unlike plain `#size`) — worth adding both the bare
  alias and the block/argument forms together rather than just the
  alias, since an LLM reaching for `#count` is at least as likely to
  want the filtered form.

- **Quoted Symbol literals (`:"..."`) don't decode backslash escape
  sequences.** Found 2026-08-13 fixing the identical gap for String
  literals (`decode_string_escapes`, parser.cr) — plain and
  interpolated strings now decode `\n`/`\t`/etc. correctly, but the
  quoted-Symbol construction site (`SymbolLiteral.new(tok.lexeme
  .lstrip(':').strip('"').strip('\'')...)`) was deliberately left
  untouched in that same pass, since its quote-stripping approach is
  structurally different (chained `lstrip`/`strip` rather than the
  index-based `strip_quotes`) and riskier to edit without dedicated
  attention. Lower priority than the String fix was — quoted symbols
  with embedded escapes are rare — but the same category of gap.

- **`Integer`/`Float` are both missing `#divmod`.** Found 2026-08-13
  triaging `spec/scripts/mruby/float.rb`'s commented-out `Float#divmod`
  block. Real Ruby's `#divmod` returns `[quotient, remainder]` as a
  single call — `/` and `%` already work individually (opcode-level,
  `ValueOps.div`/`.mod`) so this is purely a convenience wrapper
  around two things that already work correctly on their own, not a
  new arithmetic primitive. Lower priority than the other Data &
  builtin types entries here — no known common idiom depends on it
  the way `Integer#times` or `Array#first` did.

- **`Range` beyond `Integer` (and whatever else has a working
  `#succ`) — String ranges, custom-object ranges — isn't supported.**
  Long-standing, untriaged since the original 2026-07-14 handoff
  bundle — split out 2026-08-10 on review. `Range#each`'s advance
  mechanism (`vm.cr`, the `#succ`-calling case) is already generic
  over anything with a working `#succ`, not hardcoded to `Integer` —
  so this narrows to whatever's still missing beyond that (bound-type
  validation at construction, `#include?`/`#cover?` for non-`Integer`
  bounds, string ranges specifically since `String#succ` needs its
  own char-advance logic Ruby has and Adjutant may not). Not yet
  traced further than that — worth confirming exactly which piece is
  missing (a quick `("a".."e").each` test) before scoping the fix,
  rather than assuming the whole feature is absent when `#each`'s own
  mechanism already generalizes.

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
- **Native functions have no positional-arg defaults or arity
  binding — everything is hand-rolled `args` indexing today.** Found
  2026-08-09 while designing native keyword argument support (see
  git history/`DEVELOPMENT.md`'s "Native keyword arguments" section
  for what DID ship): a native function reads `args` directly with
  its own ad-hoc "was this supplied" convention inline (e.g.
  `testing/assert_module.cr`'s `assert`: `args.first?.try { ... } ||
  "assertion"`) — there's no `Param`-equivalent list, no arity check,
  no declared-default concept at all for POSITIONAL native args
  (kwargs now have declared names via `NativeCallable#kwarg_names`,
  but still no defaults of their own either — see that section).
  Deliberately scoped OUT of the kwargs work rather than done
  together: real positional defaults would need a `bind_args`-
  equivalent binding layer for native calls (a `Param`-like list
  matched by POSITION, evaluated/defaulted before the Crystal block
  runs), almost certainly a changed native function signature (a
  pre-bound, defaults-already-applied `Array(Value)` rather than raw
  `args`, since asking every native function to keep hand-rolling
  `args.first?` defeats the point), and would touch every existing
  `define_native`/`define_native_method` call site to adopt the new
  shape (or leave two conventions live side by side indefinitely) —
  a materially larger, more invasive change than kwargs turned out to
  be. Not blocking anything today; flagged for whoever next writes a
  native function wanting this so it isn't rediscovered cold.

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
  not undecided design mechanics) is clearer. Superseded by the
  `Legate` design work (see `LEGATE.md`) — this entry can be removed
  once `Legate` implementation lands.

### Legate

- **Deletion consumes no budget of any kind except wall clock.**
  Found 2026-08-28 implementing `rm.cr`. `Budget` (`legate/budget.cr`)
  models exactly two quantities — bytes read and bytes written — and
  `Legate.rm` moves neither, so there is nothing for it to record and
  no `record_delete` to call. Consequence: a script holding a `delete`
  grant can remove an unbounded number of entries, of unbounded total
  size, and the only limit it can ever hit is `wall_clock` (checked
  once per `authorize_delete` call, so a single `rm(recursive: true)`
  over an enormous tree doesn't even get that mid-operation). Will Fix
  rather than Must Fix: nothing behaves *wrongly* — the `delete` grant
  is doing its real job of bounding *where* deletion can happen, and
  §7's limits table names no deletion quantity, so this is arguably
  the design as specified rather than a gap in the implementation of
  it. But "where" without "how much" is a weaker guarantee than the
  read/write side gets, and it's worth a deliberate decision rather
  than silence. Fix shape not scoped — needs a call on whether the
  right quantity is entries removed, bytes reclaimed, or neither, and
  that's a LEGATE.md §7 amendment, not a code change.

- **§2.7's `include Legate::Read` submodule-include feature (dropping
  the `Legate.` prefix, e.g. `include Legate::Read; read("x")`) isn't
  implemented at all — no code references it anywhere.** Found
  2026-08-27, systematic audit of the read-verb slice against
  LEGATE.md. Not a bug — nothing currently shipped is broken by this
  — just real, specified surface (§2.7's own worked example) with
  zero implementation, worth tracking explicitly rather than
  rediscovering later. Will Fix rather than Must Fix: every verb is
  already reachable fully-qualified (`Legate.read(...)`, §2.7's own
  "available fully qualified, always, with no setup"), so the
  submodule form is sugar, not something currently blocking a script
  from doing anything. Fix shape not yet scoped — likely needs each
  grant-category submodule (`Legate::Read`, `Legate::Write`, ...) to
  actually exist as an includable module whose methods delegate to
  the same native singleton methods already bootstrapped on `Legate`
  itself, rather than a second copy of each verb's implementation.

- **`Legate.grep`'s documented `Timeout` (LEGATE.md §4.1) doesn't
  actually raise `Legate::Timeout`.** Found 2026-08-27 implementing
  `grep.cr`: unlike every other §4.1 verb, grep's own Raises list
  includes `Timeout` — the only sensible reading is that a scan across
  a large fileset should be able to notice it's taking too long
  MID-scan, not just at the single up-front broker call every other
  verb makes once. What `grep.cr` actually does is call
  `Budget#check_wall_clock!` once per file in its scan loop (real,
  working protection against a runaway multi-file scan) — but that
  raises the FATAL, unrescuable `Legate::FatalSignal(:exhausted, ...)`
  (budget.cr), not the script-catchable `Legate::Timeout` RuntimeError
  class (exceptions.cr) LEGATE.md's own text names. No kwarg or
  default duration for a SEPARATE, grep-local, recoverable timeout is
  documented anywhere — inventing a second, independent timer with
  its own semantics felt like more new, unspecified design surface
  than one verb's implementation should decide unilaterally. Needs a
  real decision: either LEGATE.md's text is describing the existing
  fatal wall-clock mechanism loosely (in which case the doc should
  stop implying a script can `rescue` it), or grep genuinely needs its
  own recoverable per-call deadline (in which case its kwarg/default
  need designing first).

- **No terse, agent-facing reference doc for Legate (and Adjutant's
  Ruby subset generally) exists yet.** `LEGATE.md`/`ERRORS.md`/
  `SCOPE.md` are correctness/completeness documents for a human
  implementer, not what a small model (target: 16K+ context) should
  read to learn what to write — different audience, different job,
  and padding a small model's context with design rationale it can't
  act on costs it real task room. Deliberately deferred, not
  overlooked: nothing about the verb surface is stable yet, so
  anything written now would describe intent rather than real
  signatures/errors/edge cases, and the actual hard-to-infer-from-
  Ruby-subset-syntax spots won't be known until scripts are written
  against a real implementation. Revisit once `Legate` verbs exist and
  are being dogfooded — likely worth generating this doc from
  `LEGATE.md` (e.g. via a machine-extractable annotation convention on
  verb signatures) rather than hand-authoring a parallel prose doc, so
  the two can't silently drift apart.

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
