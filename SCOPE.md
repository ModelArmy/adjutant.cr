# Scope

Outstanding work: the known defects and gaps. HANDOFF.md says how to
work; this file says what is left.

Deliberate exclusions are not tracked here; they are in
[UNSUPPORTED.md](./UNSUPPORTED.md). The closing section explains the
difference.

An item lives in exactly one of the two sections below, and is removed
when resolved rather than marked done; the commit log is the history.
An entry names where to start (a file, a method) and says whether the
defect was predicted by reading the code or confirmed by a spec or a
model (HANDOFF.md §3.4).

## Must Fix

Security and policy defects, anything Adjutant accepts and then runs
differently from Ruby (HANDOFF.md §3.1), and changes that get dearer
after 1.0. Ordered for working through: security and policy defects
first, then the Ruby divergences, then design work on policy and
configuration.

None open.

## Will Fix

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

Grouped by capability so adjacent work is easy to spot — within a group,
still roughly ordered by how cheap/independent the fix is.

### Parser / lexer gaps

Small, mechanical, independent of each other — good candidates for quick
wins.

- **`require` parses only as a statement.** `parse_statement`
  dispatches `KwRequire` to `parse_require`, but `parse_primary`
  doesn't accept it, so `loaded = require "x"` and `require("x") if
  ok` raise P002. Found writing the require specs. The call already
  returns true or false, which a script can't yet capture. Fix: parse
  `require` (and `load`) as a primary expression.

- **`defined?` and `Module#const_defined?` don't exist.** Found in the
  mruby sweep (`test/t/syntax.rb`, `spec/scripts/mruby/float.rb`).
  `defined?` lexes as an ordinary method name (`lexer.cr`), so
  `defined?(x) ? x : default` raises instead of answering. It needs a
  keyword, parser support, and a check per operand kind: expression,
  `self`, local, method and constant (globals are excluded, U011).
  `Object.const_defined?(:Float)` is separate work, an ordinary native
  method.

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

- **A bare `next`, `break` or `return` directly before `}`, `end` or
  `else` probably fails to parse.** Predicted 2026-09-24 while fixing
  the modifier `if`/`unless` case; not yet confirmed by a spec or a
  model. `jump_value_follows?` (parser.cr) treats only a newline, `;`,
  end of file and a modifier `if`/`unless` as "no value here", so in
  `items.each { |x| next }` or `if a then break end` the parser tries
  to read `}` or `end` as the keyword's value. Ruby accepts both. The
  likely fix is adding `RBrace`, `KwEnd` and `KwElse` to that list,
  once a failure confirms it.

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
- **An operator Symbol right after `:` in a ternary lexes as a Symbol.**
  The lexer reads `:+`, `:<=>` and the other operator Symbols wherever
  an expression can start, so `x ? a :-1` lexes `:-` as a Symbol and
  fails to parse. Ruby reads it as a ternary. Spacing it as
  `x ? a : -1` works. The fix is tracking an open `?` in the lexer.

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

- **Runtime diagnostics have a line but no column, so no caret.** The
  AST carries columns, but `Instruction` (`bytecode.cr`) and `Frame`
  (`vm.cr`) record only a line. On a dense line (`foo(bar.baz, qux[i])`)
  the reader can't tell which call failed. A column on every
  instruction costs memory per instruction; a table from instruction
  index to column, filled only where the compiler emits a call, may be
  cheaper.

- **`ParseError` and `CompileError` keep a message-only constructor
  nothing uses.** Every raise site in `parser.cr` and `compiler.cr`
  builds a `Diagnostic`; `ParseError.new(message, line, column)` and
  `CompileError.new(message, line, column)` are reached only by
  `diagnostic_spec.cr:172`. `HostStateError.new(message)`
  (`diagnostic.cr`) likewise has only a spec caller. Removing them
  makes `diagnostic` non-nilable on those classes and lets callers
  drop their nil handling. `InternalError.new(message)` is still used
  and stays.

- **U008, U009, U012–U014, U015's `undef` and U021 are decided but
  not enforced.**
  See `UNSUPPORTED.md` for each. Using one falls through to a generic
  undefined-name, undefined-method or parse error that doesn't name
  the construct, the failure shape `UNSUPPORTED.md`'s second principle
  forbids. U021 costs the most in practice: a model reaching for
  `File.read` or `ENV` is told the constant is uninitialized, not that
  `Legate.read` or `Legate.env` is the way. Enforcing U021 is mostly
  entries in `ErrorCatalog::EXCLUDED_CONSTANTS` (`File`, `ENV`, ...)
  and `EXCLUDED_METHODS` (`system`, `exec`, ...), which are consulted
  only after resolution fails. U008, U009 and U021 are
  lookup-after-resolution-fails checks, the mechanism U005–U007 use
  (`dispatch_call` and constant resolution, `vm.cr`); U012–U014 and
  U015's `undef` fail in the parser today, so each needs its own
  enforcement point. U015's hooks are enforced at compile time.
  Backticks and `%x{}` have no case in the lexer at all, so theirs is
  there.

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

- **Indexing can't reach a script-defined `[]` or `[]=`.**
  `vm_indexing.cr` calls an object's native `[]` and `[]=`, and a
  Proc's `call`, synchronously from inside the index opcodes. A script
  method would need a frame pushed and the dispatch loop to resume it,
  which those opcodes can't do. Nothing needs it today: a script can't
  define `[]` or `[]=` at all (U017). If that changes, the index
  opcodes need to dispatch through the ordinary call path.

- **`*`, `%` and the bitwise operators don't dispatch to an object's
  own method.** `exec_add`, `exec_sub` and `exec_div` (`vm.cr`) call a
  left-hand object's own `+`, `-` or `/` (Time uses the first two,
  `Legate::Path` the third); `Op::Mul`, `Op::Mod`, `Op::BitAnd` and
  the rest go straight to `ValueOps`. No builtin or Legate class
  defines one of those, and a script can't (U017), so today an object
  gets NoMethodError from `operator_defined?`. A native class that
  defines one would get a TypeError instead of its method.

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

- **A TypeError from a binary operator renders a nil right-hand side as
  nothing.** `ValueOps` builds its messages with `#{a}` and `#{b}`, and
  `Value#to_s` of nil is the empty string, so `1 + nil` reports
  `cannot add 1 and `. The gap is where the answer is. `inspect` gives
  `cannot add 1 and nil`. (A nil left-hand side now raises
  NoMethodError before `ValueOps` runs.)

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

- **String repetition** (`"ab" * 3`). `ValueOps.op` (the method backing
  `*`, see `value_ops.cr`) has real `Integer`/`Float` cases but no
  `String` one — `+`, `==`, and `<`/`<=`/`>`/`>=` all DO already work for
  strings at the opcode level (see `ValueOps.add`/`.equal?`/`.compare`),
  so this is narrowly about `*` specifically. Noticed while bootstrapping
  the `String` builtin class (Phase 4a of base types); out of scope there
  since that work only wires up native METHODS, not opcodes.

- **No structured audit-trail export beyond `RiskFlowLog` itself.**
  Nothing turns a `RiskFlowLog` into a saved/replayable session record.
- **The approval cache** (avoid re-prompting for an already-approved
  origin→sink flow within one script run) — still not designed. More
  pressing since risk-flow checks moved to each subject: `fetch` asks
  per redirect hop, and `mv` per authority. If the cache's scope (per
  run, per origin and subject) needs the host's say, it changes the
  decision callback's contract, and belongs in Must Fix.

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

- **`Integer#[]` takes only a bit index.** `n[i, len]` and `n[i..j]`
  (Ruby 2.7) raise ArgumentError and TypeError (R046, R048) rather
  than returning the bits.

- **Optional arguments Adjutant doesn't implement raise ArgumentError.**
  Each builtin method declares the arity it implements, so an argument
  Ruby accepts and Adjutant would ignore raises R046 instead of
  producing a different answer: `Array#pop(n)`, `#min(n)`, `#max(n)`,
  `#any?(pattern)`, `#all?(pattern)`;
  `Range#min(n)`, `#max(n)`, `#last(n)`; `String#to_i(base)`,
  `#upcase`/`#downcase`/`#capitalize` options, several prefixes to
  `#start_with?`/`#end_with?`, `#match(str, pos)`; `Regexp#match` and
  `#match?` with a position; `MatchData#[](start, length)`;
  `Time.at`'s unit; `Time.utc`/`local`'s ten-argument form;
  `Time#localtime(offset)`, `#getlocal(offset)`; `Comparable#clamp`
  with a Range; `include` and
  `extend` with several modules. Each is supported by
  implementing the argument and widening the declared arity.

### Streamed fetch on Windows

- **A script that raises inside a streamed `Legate.fetch` walk
  terminates the host process on Windows.** Found 2026-09-04 via CI.
  Exit `0xC0000409` — a fail-fast during exception unwinding, aborting
  inside MSVC's `FindAndUnlinkFrame`, which is an integrity check on
  the registered SEH frame list. Uncatchable by construction: it fires
  before any handler, and rescuing every exception changes nothing.

  **Believed to be a Crystal runtime defect rather than an Adjutant
  one**, on this evidence. Each of the three ingredients passes alone
  and only the combination dies: a raise unwinding through VM frames
  is fine (`begin_rescue_ensure/vm_spec.cr`), the same shape over a
  FILE-backed stream is fine (`open_sources_spec.cr`'s "closes a
  stream whose walk raised"), and cancelling a socket-backed stream
  without unwinding is fine (a `break` instead of a `raise`). It
  reproduces on Crystal 1.20 and latest, and does NOT need the test's
  in-process server — it crashes just the same against a static file
  server in another process, so it reaches real deployments rather
  than only the harness. Six standalone reproductions were attempted
  and none crashed; the trigger needs something structural the VM
  supplies that a small program does not.

  `verbs/fetch_stream_spec.cr`'s "closes the connection when the
  script raises mid-walk" is `pending` under `flag?(:windows)` —
  skipped, not deleted, so the coverage returns when the runtime is
  fixed. **Windows is therefore not a supported host for streamed
  `fetch`.** Buffered `fetch` was never tested and may or may not be
  affected. Not blocking on macOS or Linux, which is where the early
  access work is aimed.

  Parked deliberately: there is no sound fix available in this repo,
  and the investigation has already cost more than the platform is
  currently worth. To pick it up, the route that worked was cutting
  DOWN from the crashing spec, not building UP from a small program.

### Providers

- **Effect providers are named, not loaded.** Each provider claims
  and parses its own keys in the policy document, but
  `Policy.default_sections` lists core's and Legate's,
  `Policy.grants_from` assembles their shares into a
  `Legate::Grants`, and the `Interpreter` builds Legate's broker
  itself. A second provider would edit all three. Loading providers
  generically would hand each its `PolicyShare` and let it build its
  own broker. There is no second provider to design that against.
  `Authority` stays a closed enum whatever is loaded: it keys
  `RiskFlowRule`, `RiskFlowPolicy.reject_all` must cover every
  member, and the manifest's vocabulary must not depend on which
  providers are present.

### Static risk assessment

- **LEGATE.md §10's static analyser isn't built.** No grant
  inference, exception gate, inclusion ledger or raise-set inference
  exists, and `risk_walker.cr` doesn't mention Legate. Nothing depends
  on it for safety: §9.2's fatal tier is uncatchable at runtime
  whatever the analyser does. Building it starts with a design
  question, what the "effectful surface" is. §10.4 counts 19 verbs
  (§4.1 to §4.5); 16 declare an `Authority`; 25 exist. The answer sets
  what grant inference and raise-set inference cover. §10.1 keys
  inference on registered providers, not on Legate alone.

### Legate

- **Legate verbs don't check positional arity.** Verbs are registered
  with `define_native_singleton_method`, whose arity defaults to any
  count, so `Legate.read(path, extra)` ignores `extra`. Missing
  arguments already raise each verb's own code (R035, R040, R041,
  R043). Declaring each verb's arity would make extras raise R046 like
  the Legate classes' methods, which do declare theirs.

- **A script can't take over a body-less redirect.** With `redirects:
  0`, a redirect raises `Legate::TransportError`; only a request with a
  body gets `Legate::RedirectError`, which carries `status` and
  `location`. Since a cross-origin hop drops every header but four
  defaults and those `net.redirect_headers` names, a script whose target
  needs another has no way to re-issue the request itself. Fix: raise
  `Legate::RedirectError` whenever the redirect budget is spent at 0.
  Wait for a live case before building it.

- **`Legate::Path#under?` doesn't resolve `..`.** It compares
  components lexically, so `Legate::Path.new("/work/../etc")` is
  `under?` `/work`, and `split_path` splits on `/` only, so a Windows
  path is one component. The broker doesn't use it, since grants
  resolve with `realpath`, so this is no escape; but a script using
  it as a boundary check, as LEGATE.md §5.1 invites, gets a wrong
  answer. The fix is normalising `.` and `..` before comparing, and
  refusing (or documenting) a relative path that climbs above its
  start.

- **Audit records lack §8.7's bytes, duration and argument detail.**
  LEGATE.md §8.7 asks for bytes moved, duration, and arguments with
  bodies hashed; its status table already says "narrower than
  specified". An `AuditRecord` has timestamp, verb, subject,
  authority, decision and exception class. The broker writes it before
  the effect runs, so bytes and duration aren't known yet; meeting §8.7
  needs the record completed after the verb finishes, or a second
  record. Unchecked: whether a stream's re-iteration writes a distinct
  record, and whether a fatal exception is recorded before unwinding,
  both of which §8.7 also requires.

- **`Legate::Stream` implements 9 of the ~35 operations §6
  specifies.** Found 2026-09-21 in the census for the agent skill.
  `stream.cr` defines `map`, `select`, `reject`, `take`, `first`,
  `each`, `count`, `sum` and `to_a`; the rest of §6.2–§6.4 (`each_slice`,
  `with_index`, `find`, `min`/`max`, `reduce`, `top_by`, `tally`,
  `sort_by`, `group_by`, …) do not exist, yet LEGATE.md §0 marks §6
  "Built". §0 now says "Partial" and lists the nine. Build the rest by
  what the skill exam shows models actually reach for.

- **`Stream#to_a`'s `TooLargeError` hint names methods that don't
  exist.** Found alongside the above. The message recommends
  `each_slice`, `top_by` or `tally`, none of which a stream has, so a
  model that follows the diagnostic gets a second error. LEGATE.md §9's
  `TooLargeError`/`TooManyError` rows have the same problem. Until those
  operations exist, the hint should name what does: `each`, `take` or
  `first(n)`.

- **The pinned socket's TLS path is only exercised when a transcript
  is RECORDED.** Found 2026-08-30. The plain socket half is covered
  offline: `http_client_pinning_canary_spec.cr`
  stands up a loopback HTTP server and pins to it from a client whose
  hostname (`canary.invalid`) cannot resolve, so a response can only
  arrive if the pinned address was used and the name never consulted.
  What that spec does NOT cover is the `OpenSSL::SSL::Socket::Client`
  branch — SNI and certificate verification against the logical
  hostname while connected to the pinned address — because that needs
  a local TLS server with a certificate the client will accept. Will
  Fix. The practical verification meanwhile is re-recording: deleting
  a transcript under `spec/transcripts/` and re-running with
  `WIRETAP_RECORD=1` forces a real TLS handshake through the pinning
  override. Fix shape: a
  self-signed certificate generated per-run plus a client context
  trusting it, which is a chunk of setup worth doing deliberately
  rather than inline in a spec.

- **`Legate.fetch`'s `body:` does not stream an Enumerable.** Found
  2026-08-30. §4.5 says `body:` accepts a String or an Enumerable "so
  uploads stream"; an Array is currently joined into a single String
  before the request is built, so the memory saving the sentence
  promises does not happen. Will Fix. The response half of streaming
  has since landed (`Utils::HttpResponseStream` plus `stream: true`),
  and this is the remaining half: it needs the REQUEST body written
  incrementally to the connection rather than materialised first,
  which `HTTP::Request` accepts as an `IO` but Legate does not yet
  supply. Note the interaction already settled in §4.5 — a redirect on
  a request that carried a body is handed to the script, so a
  single-pass upload stream never has to be replayed.

- **`Legate.records` cannot consume a stream.** Found 2026-08-30,
  logged 2026-08-31 after `stream: true` landed.
  `Legate.records(path, format:)` opens the path itself, so a body
  from `Legate.fetch(..., stream: true)` cannot be fed to it — a
  script wanting to pull JSONL rows off a network response has to
  buffer the whole thing first, which defeats the streaming it just
  asked for. Will Fix. The plumbing is closer than it looks: both
  parsers already consume an iterator rather than a file specifically
  (`:jsonl` builds on `Lines::LineIterator`, `:csv` on
  `CSV::Parser`), so what is missing is a second entry point.
  Undecided whether that is `Legate.records(stream, format:)` or
  `response.records(format:)`; the second reads better at a call site
  but puts a parsing concern on `Response`.

- **`Response#json` cannot parse a streamed body.** Found 2026-08-30,
  logged 2026-08-31. `#json` raises `Legate::MalformedError` on a
  non-String body, so `stream: true` and `.json` are mutually
  exclusive. Correct as it stands — the alternative is silently
  buffering a body the script explicitly asked not to buffer — but it
  means a large JSON document has no streaming path at all. Will Fix
  eventually, and materially harder than the `records` entry above: it
  needs an incremental JSON parser, not just a different entry point,
  and Crystal's `JSON::PullParser` over a chunk iterator is the
  obvious starting point rather than a settled design.

- **No wall-clock bound on a script or on a held-open stream.** Found
  2026-08-30 designing `stream: true`. `Legate.fetch`'s `timeout:`
  becomes the client's connect and read timeouts, which bound each
  individual READ but not total duration: a server dribbling one byte
  every few seconds keeps a connection open indefinitely without ever
  tripping a read timeout, and a script holding that stream stays
  alive with it. `Limits#wall_clock` exists and is unenforced for the
  same reason. Will Fix, and deliberately NOT solved inside one verb —
  this is the same problem as an infinite loop in a script, and wants
  one watchdog at the `Interpreter#eval` boundary rather than a
  duration check invented separately in `fetch`, `exec`, and every
  future long-running verb. The run-teardown seam added for
  `open_sources` is the natural place to hang it, since it already
  owns "this run is over, release everything."

- **IPv6 literals can't be written in a `net.hosts` rule.** Found
  2026-08-30 building `net_rule.cr`. The scalar parser splits a
  `host:port` entry on the colon, which is unambiguous for a DNS name
  and hopeless for `2001:db8::1`; bracketed forms
  (`[2001:db8::1]:8443`) aren't handled either. The parser *rejects*
  both loudly with an `ArgumentError` at policy-load time rather than
  mis-splitting on the first colon, so nothing silently misbehaves — a
  policy naming an IPv6 literal fails to load instead of quietly
  building a rule for a host that doesn't exist and then denying every
  real connection to it with a baffling reason. Will Fix rather than
  Must Fix: the same grant is expressible by hostname today, and the
  failure mode is loud and immediate. Fix shape: bracket-aware
  splitting in `NetRule.parse`, plus a decision on whether a bare IPv6
  address should be grantable at all, given §8.2's address-range
  checks are about to reject most of the interesting ones anyway.

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

- **`Legate.grep`'s documented `TimeoutError` (LEGATE.md §4.1) doesn't
  actually raise `Legate::TimeoutError`.** Found 2026-08-27 implementing
  `grep.cr`: unlike every other §4.1 verb, grep's own Raises list
  includes `TimeoutError` — the only sensible reading is that a scan
  across a large fileset should be able to notice it's taking too long
  MID-scan, not just at the single up-front broker call every other verb
  makes once. What `grep.cr` actually does is call
  `Budget#check_wall_clock!` once per file in its scan loop (real,
  working protection against a runaway multi-file scan) — but that
  raises the FATAL, unrescuable `Legate::FatalSignal(:exhausted, ...)`
  (budget.cr), not the script-catchable `Legate::TimeoutError`
  RuntimeError class (exceptions.cr) LEGATE.md's own text names. No
  kwarg or default duration for a SEPARATE, grep-local, recoverable
  timeout is documented anywhere — inventing a second, independent timer
  with its own semantics felt like more new, unspecified design surface
  than one verb's implementation should decide unilaterally. Needs a
  real decision: either LEGATE.md's text is describing the existing
  fatal wall-clock mechanism loosely (in which case the doc should stop
  implying a script can `rescue` it), or grep genuinely needs its own
  recoverable per-call deadline (in which case its kwarg/default need
  designing first).

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

- **`Legate.log` is `Legate.log(message, fields = {})`, not the
  spec'd `Legate.log(message, **fields)`.** Built 2026-09-08 (§4 step
  2). Adjutant's native-call dispatch has no wildcard-kwarg mechanism
  — every native method declares a FIXED `kwarg_names : Set(String)`
  (`NativeCallable#kwarg_names`), and `VM#check_unknown_native_
  keywords!` rejects any name outside it; an empty declared set (the
  default, and every native method until now) rejects every kwarg
  name outright. There is no "accept anything" escape hatch. Building
  real support for that — a sentinel `kwarg_names` value, or a
  parallel dispatch path — would be a genuine VM-level change, and
  doing it for the sake of one convenience verb's exact spelling felt
  disproportionate; the positional-Hash form carries identical
  information (`Legate.log("done", {status: "ok"})` vs the spec'd
  `Legate.log("done", status: "ok")` — same data, different
  punctuation). Worth doing properly — generalized native kwarg
  support — if a second verb ever wants the same thing; not before.
  `legate/verbs/log.cr`'s own top comment has the full reasoning.

  **Addendum, confirmed against a live `crystal build` the same day:**
  the positional-Hash form turned out not to be merely a dispatch
  workaround — it's load-bearing for a SECOND, independent reason.
  `Log::Metadata`'s own top-level entries are `Symbol`-keyed
  (`Log::Metadata#setup`, Crystal stdlib), and Crystal symbols cannot
  be created dynamically at runtime AT ALL — only from a literal
  known at compile time. `fields`' keys are chosen by the SCRIPT at
  runtime, so they could never have been Metadata's own top-level
  entry names regardless of how they arrived (kwarg spray or Hash
  argument) — a real `**fields` implementation would have hit this
  exact wall too. The fix (`legate/verbs/log.cr`): nest the whole
  `fields` Hash one level down, under the single Symbol key `:fields`
  — a literal in that file, known at compile time — since `Log::
  Metadata::Value::Type` explicitly allows a String-keyed Hash as a
  NESTED value, just not as Metadata's own top-level keys. Worth
  knowing for whoever eventually builds generalized native kwarg
  support per the paragraph above: it would face the identical
  Symbol-key wall at the Log layer, unrelated to and not solved by
  fixing VM dispatch.

- **`Legate.scratch`'s directory is emptied at the end of every
  `Interpreter#eval` call, not at the end of an agent's whole
  session.** Built 2026-09-08. §4.7 says scratch "is emptied when the
  script exits," and this codebase's own existing vocabulary already
  settles what "the script" means for exactly this kind of resource:
  `OpenSources`'s own comment ("SCOPE IS THE RUN, NOT THE PROCESS")
  defines it as one `eval` call, specifically because an Interpreter
  is long-lived and may run many. Applied the same rule to scratch
  for consistency, but it is a real product decision with a real
  cost: an agent doing multi-step work across several `eval` calls on
  one Interpreter (exactly DEVELOPMENT.md's own description of the
  intended use) gets a FRESH scratch directory every call, so
  anything written to scratch in one step is gone by the next. If
  that turns out to matter in practice, the fix is either a
  session-scoped scratch dir with its own (currently nonexistent)
  session-end teardown hook, or leaning on a real `write:` root for
  anything meant to survive across steps and reserving `scratch` for
  genuinely single-call incidental space. `legate/broker.cr`'s
  `@scratch_dir` comment has the full reasoning; not revisited here.

- **`Legate.now` reuses the core `Time` class rather than a
  `Legate::Time`, and its RubyClass is looked up at CALL time, not
  bootstrap time.** Built 2026-09-08. Worth recording as a pattern,
  not just a fact about this one verb: `Interpreter#bootstrap_
  builtin_classes` registers `Time` (and any other core builtin
  reached via `register_builtin_class` outside `bootstrap_legate`
  itself) AFTER `bootstrap_legate` runs, not before — so any FUTURE
  Legate verb that needs to construct a value of some OTHER
  core-builtin type will hit the identical ordering hazard, and the
  identical fix (`interp.get_global(name)` inside the native block,
  deferred to call time) applies. Didn't reorder `bootstrap_builtin_
  classes` itself to register `Time` earlier — it's a shared sequence
  this file doesn't own, and the call-time lookup sidesteps the
  problem entirely for a fraction of the risk. Also: `Legate.now`'s
  "frozen" is aspirational, same as `Legate::Response`'s own
  documented "frozen" claim (`legate/response.cr`) — Adjutant freezes
  only Strings, and has no `freeze`/`frozen?`; a script can still
  mutate the returned value via `#utc`/`#gmtime`/`#localtime`. Not specific to this verb,
  just newly relevant to it.

- **`Compiler::OVERLOADABLE_OPERATOR_NAMES` names the opposite of
  what it holds.** It lists the operator method names a script may
  not define (U017), because each compiles to a fixed opcode. For the
  code-cleanup phase: rename it (`FIXED_OPCODE_OPERATORS`, say).

- **Legate keeps aliases for types that moved to core.**
  `legate/open_sources.cr`, `legate/audit_log.cr` and
  `legate/budget.cr` exist only to alias `Closable`, `OpenSources`,
  `AuditRecord`, `AuditLog` and `Budget` under `Legate::` names, and
  28 references in `src/` and `spec/` still use them. For the
  code-cleanup phase: rename the references to the core names and
  delete the three files.

## Deliberate non-goals

Permanent exclusions are in [UNSUPPORTED.md](./UNSUPPORTED.md), a
reference rather than a work queue. To decide where something belongs:
an item here is expected to leave by being fixed; an entry there leaves
only if the reasoning that excluded it stops holding, which is a design
conversation of its own.
