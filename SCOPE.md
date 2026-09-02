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

- **`write`, `cp` and `mv` silently destroy an existing destination,
  and declare themselves safe while doing it.** Found 2026-09-01, in
  the design conversation preceding the step 4c risk sweep. §4.3
  mandates write-as-atomic-rename, and both `write.cr` and `cp.cr`'s
  `copy_file` rename over an existing file with no check — only a
  DIRECTORY target is refused. `mv.cr`'s `check_destination` is
  halfway there already: it refuses to replace a file with a directory
  and refuses a non-empty directory, but renames over an existing
  same-kind file. All three then declare `Reversibility::Yes` /
  `Severity::Info` (`mv` declares `No`/`Warning`, but for the wrong
  reason — see below). Must Fix rather than Will Fix on the failure
  shape: the perimeter cannot catch this. A destination inside a
  granted write root is exactly what the grant permits, so `Grants`
  answers yes and the data is gone; there is no layer below this one
  that notices.

  Fix shape, decided in that conversation and not to be relitigated:
  **replacement becomes opt-in via a bang variant.** `write`/`cp`/`mv`
  raise `Legate::Conflict` (recoverable, and already named in §4.3 and
  §4.4's Raises lines) when the destination exists; `write!`/`cp!`/
  `mv!` do what the current verbs do. The bang is Ruby's own
  dangerous-variant convention and reads consistently across all
  three: "do the more destructive thing you would otherwise refuse."
  For `mv!` this is a small extension of an existing refusal rather
  than new machinery.

  Declarations after the split:

  - `write`, `cp` — genuinely `Yes`/`Info`. Once they cannot destroy,
    there is nothing to declare.
  - `write!`, `cp!` — `No`/`Warning`.
  - `mv` — `Yes`/`Info`, and note this CHANGES its current
    declaration. A move preserves the information: `relocate` is
    `File.rename` whenever source and destination share a filesystem,
    and the `EXDEV` fallback is deliberately ordered copy-then-delete
    so a partway failure duplicates rather than loses. Nothing is
    destroyed in either path; the entry ends up somewhere else. The
    current `No`/`Warning` came from §4.4's "a move both destroys and
    creates," which is about the GRANTS a move needs, not about what
    survives it.
  - `mv!` — `No`/`Warning`, because clobbering the destination
    destroys that file, which is the same thing `cp!` does.

  Also add an `Effect::MovesFiles` member (`RiskTag::MovesFiles` if
  the `Effect` rename below has not landed yet). `mv` carries it
  ALONE — saying `DeletesFiles` of a move implies destruction that
  does not occur, and pairing the two is worse than either. `mv!`
  carries `MovesFiles` and `DeletesFiles`, the latter honestly
  referring to the clobbered destination — a real, unrecoverable loss
  of a file the script never named as a source. This makes the
  effect vocabulary deliberately ASYMMETRIC with the grants a verb
  needs (`mv` still requires `delete` + `write`), which is correct
  once the two enums are separated: grants answer "what authority,"
  effects answer "what consequence." Nothing infers grants from
  effects — §10.1 SPECIFIES inferring them by walking the call graph
  for `Legate.*` names (unimplemented; see the §10 entry below) — so the asymmetry costs the analyser nothing.

  Do this BEFORE writing the step 4c sweep. Writing assertions
  against the current declarations would pin behaviour we have already
  agreed is wrong.

- **`rm` conflates deleting a file with deleting a tree.** Found
  2026-09-01, same conversation, as a consequence of the bang
  convention above. Recursion only ever means directory-tree walking,
  so `recursive:` was always mis-attached to a verb that also deletes
  single files — and `rm!` cannot mean "recursive" without the bang
  meaning something different on `rm` than it does on `write`/`cp`/
  `mv`. Split the verb instead: `rm` deletes files, `rmdir` deletes an
  empty directory and raises `Legate::Conflict` on a non-empty one,
  `rmdir!` takes the tree. The bang then reads identically everywhere.

  This REVERSES §4.4's explicit "`rm` subsumes `rmdir` and `unlink`,"
  which was a deliberate simplification. Recording why, since the spec
  otherwise loses a decision without gaining a reason: the bang
  convention did not exist when that line was written, and it is what
  makes the extra name earn its place. Update §4.4 rather than leaving
  the two in disagreement.

  Three loose ends, deliberately NOT decided here — raise before
  writing code:

  - **`rm`'s return type.** §4.4 has it return the number of entries
    removed, which is only interesting for a recursive delete. A
    files-only `rm` returns 0 or 1; probably a Bool, possibly
    nothing. `rmdir!` keeps the count.
  - **§2.3's "`rm` on a missing path returns `0`"** needs restating
    per verb once there are three of them.
  - **§2.7's submodule table and §11's surface count** both move.

- **The risk flow rule key has no slot for the sink's subject.** Found
  2026-09-01, in the same conversation, from the `Legate.env`
  case. `RiskFlowRule` is `(RiskTag, Sensitivity) → RiskFlowAction`,
  so a policy can express "high-sensitivity data must not reach the
  network" but CANNOT express "this API key may go to
  `api.stripe.com` and nowhere else." That distinction is the
  difference between a policy that forbids API keys outright and one
  that lets them do the job they exist for — an env-sourced credential
  reaching a server is the normal case, not the attack.

  Note what is NOT missing: the subject. `Broker#authorize` already
  takes it (`subject` — a path for the file grants, a host for `net`,
  a binary for `exec`) and already passes it to `declare_sensitivity`
  as the provenance origin. It simply is not part of the rule key, so
  the policy table cannot discriminate on it.

  Must Fix on the same "the perimeter cannot catch this" argument as
  the destination entry above: `net_rules` decides whether a host may
  be reached at all, but says nothing about WHICH data may reach it,
  and the flow policy is the layer that is supposed to answer that.

  Fix shape: a third dimension on the rule, most likely an optional
  subject pattern reusing `SensitivityPattern`'s existing
  literal/prefix/regex matching rather than inventing a second
  matcher. Two things to settle first, neither obvious: how an absent
  pattern is read (match-any is the ergonomic default but makes every
  existing rule silently broader than a subject-bearing one), and how
  this interacts with a redirect hop, where the subject a rule was
  evaluated against is not the subject finally reached. Explicitly
  out of scope for the `Effect`/`Authority` split — that change is
  about which enum keys the rule, not how many dimensions it has.

- **Authorization is a Legate-private mechanism, but it is not a
  Legate-shaped problem.** Decided 2026-09-01, in the design
  conversation following the `Effect`/`Authority` split. `Authority`
  and `RiskFlowPolicy` are core; the perimeter that decides whether a
  given subject may be reached under a given authority is not — it
  lives entirely in `Legate::Broker`, `Legate::Grants`,
  `Legate::Authorization` and `Legate::Budget`. Anything else that
  ever needs to reach outside the VM must either reimplement that
  sequence or be bolted onto Legate, and neither is acceptable for a
  mechanism whose whole job is being the one place effects are gated.

  Must Fix rather than Will Fix on timing, not on breakage: nothing is
  wrong today, but every additional consumer makes the move dearer,
  and the last piece changes an embedder-facing config format. Pre-1.0
  is the cheap moment.

  **The seam already exists.** `Broker#authorize` takes the grant
  decision as a block (`& : -> Grants::Decision`) precisely because
  each category resolves differently. Everything before and after that
  block is generic — wall-clock, then the decision, then
  `ncc.declare_sensitivity`, then exactly one `AuditRecord` per
  outcome, with the resolved `RiskFlowLabel?` threaded back out so a
  verb can tag the data it returns. Only the block's body is Legate's.

  ### What moves to core

  - The sequence itself, `Authorization::Decision` (two fields,
    nothing Legate in it), and `AuditRecord` — whose `grant : Symbol`
    field collapses into `Authority`, since `Broker#authorize`
    currently takes both and they are the same fact spelled twice.
  - The perimeter predicates and the data they read: `check_root`,
    `check_net`, `check_binary`, and `Grants`' roots / net rules /
    exec allowlist. These are predicates over paths, hosts and
    binaries; none of them mentions a verb.
  - Run-level accounting: `wall_clock`, `memory`, `total_read`,
    `total_write`. `wall_clock` especially — SCOPE's own "no
    wall-clock bound on a script or a held-open stream" entry says the
    fix belongs in one watchdog at the `Interpreter#eval` boundary,
    and a core run-clock is where that hangs.
  - `OpenSources` and `max_open_streams`: a cap over anything
    closable, and `Interpreter#eval` already owns the teardown.
  - Core's own unrescuable denial signal.

  ### What stays in Legate

  - The verb-facing wrappers (`authorize_read`/`_write`/`_delete`/
    `_net`/`_exec`). They know about `allow_missing`, `Legate::Path`
    and which `Legate::` class to name; fourteen verbs should not be
    talking to a generic API directly.
  - The verb-shaped limits — `read_limit`, `fetch_limit`,
    `url_limit`, `stream_limit`. Named after verbs; `fetch_limit`
    cannot mean anything to a subsystem with no `fetch`.
  - §9's error tier and the script-visible class names. Core raises
    its own signal; Legate supplies the name, roughly what
    `FATAL_CLASS_NAME` already does as a constant.

  ### The plug-in shape

  The point is not just relocation — authorization becomes a
  capability a subsystem plugs into, the way Legate will:

  - **`Authority` stays CLOSED.** Six members, core, no registration.
    It keys `RiskFlowRule`, so an open vocabulary makes policy tables
    unbounded and breaks the property `reject_all` depends on ("never
    silently stops covering an Authority added later"). It is also
    what the static manifest reports, and a manifest whose vocabulary
    depends on which extensions are loaded cannot be trusted.
  - **The predicate is PLUGGABLE.** Core owns the sequence and asks a
    registered resolver whether a subject is permitted under an
    authority. Legate resolves `Write` against roots; something else
    may resolve it against a different perimeter.
  - **The config section is OPEN.** Each subsystem contributes and
    parses its own block inside one document.

  ### Interaction that does NOT move by itself

  §10.1 SPECIFIES a grant inference that walks the call graph for
  `Legate.*` names, emits the minimum policy a script requires, and
  refuses a run whose offered policy grants more. **It does not
  exist** — see the §10 entry below; nothing in `src/` infers a
  policy, and `risk_walker.cr` contains no reference to Legate at all.
  Corrected 2026-09-02, having been described here twice in the
  present tense as though it were shipped.

  So there is nothing to rekey, and this is cheaper than it looked:
  what must change is the SPEC, so that whoever implements §10.1 keys
  it on a registered provider rather than a hardcoded module name.
  Otherwise a second provider gets full enforcement and no static
  manifest, which is exactly the asymmetry the manifest exists to
  prevent.

  Worked example, since one sentence understates it. Suppose a second
  provider `Vault` gives scripts access to secrets, and a script does:

      key = Vault.secret("stripe/live")
      Legate.fetch("https://api.example.com", body: key)

  This is what WILL happen when §10.1 is built as currently written —
  a warning, not a bug report. At RUNTIME the script is already fully
  protected. `Vault.secret` is an
  `EffectProvider`, so it goes through the same core Broker: same
  wall-clock check, same perimeter decision, same
  `declare_sensitivity`, same audit record, same RiskFlowPolicy. A
  `Read`-authority rule on high-sensitivity data fires exactly as it
  would for `Legate.read`.

  STATICALLY it is misdescribed, three ways:

  - The inferred minimum policy mentions only `net`. It never says the
    script needs a `vault` grant, because the walk does not know
    `Vault` exists.
  - Over-grant refusal inverts. The offered policy grants
    `vault: [stripe/*]`; the inferred minimum does not mention
    `vault`; so the comparison sees a grant the script supposedly does
    not need, and either refuses a legitimate run or quietly treats
    the unknown section as noise.
  - The manifest under-reports. Whoever decides whether to run this is
    told the script makes a network request. They are NOT told it
    reads a live payment credential first — precisely the fact that
    would change the answer.

  So the failure mode is not an unprotected provider. It is the
  pre-run picture and the runtime enforcement disagreeing, with the
  pre-run picture being the one a human reads before consenting. A
  script can be completely enforced and still misdescribed, and
  nothing goes red when that happens: a second provider is added,
  every spec passes, and the manifest simply goes quiet about it.

  Fix shape, for the SPEC today and the implementation whenever it
  arrives: the walk collects calls to any REGISTERED provider's module
  rather than a hardcoded `Legate`, and each provider maps its own
  verbs to the authorities it declares — which is what finally makes
  `EffectProvider#authorities` load-bearing rather than documentation.

  **Do this WITH piece 4, not before it.** The walk needs to know
  which providers exist and what each one's config section is called,
  which is the same registry the config merge introduces; doing it
  first would mean inventing half a registry and reworking it a step
  later.

  ### Order, and why the config is last

  Four separable pieces, to be landed and tested independently:

  1. Perimeter to core (`Grants`, the `check_*` predicates,
     `Decision`). **Landed 2026-09-01.**
  2. Run accounting to core (the run-level half of `Limits` as
     `ResourceLimits`, plus `Budget`, `OpenSources` and
     `FatalSignal`). **Landed 2026-09-01.**
  3. The broker sequence to core as `Adjutant::Broker` — one per RUN,
     shared by every provider, with `Legate::Broker` becoming the
     first `EffectProvider` holding a reference to it, and
     `AuditRecord` rekeyed on `Authority`. **Landed 2026-09-01.**

     Note what piece 3 did NOT add, deliberately: a resolver registry.
     Dispatch does not need one — a provider calls the broker itself
     and supplies its perimeter decision through a block, which is
     more precise than a lookup, since the provider knows which of its
     own predicates applies and core does not. The registry earns its
     place in piece 4, where the config and the inference need to
     ITERATE providers rather than dispatch to them.
  4. **One config document.** `RiskFlowPolicy` is JSON and
     agent-constructed; `Grants` parses YAML. Two formats for one
     document is history, not design. Last because it is the only
     piece that changes an embedder-facing format, and it benefits
     from the rest being settled.

     Three properties a merged config MUST preserve, each a decision
     made deliberately:

     - **No permissive default.** `RiskFlowPolicy` has no bare `.new`
       meaning "allow everything," so Adjutant never silently permits
       risky calls because an embedder didn't think about IFC. A
       document carrying a grants section and no risk section must
       mean `reject_all`, NOT "unset, therefore allow" — and the
       reverse likewise.
     - **Adjutant still never reads a policy path off disk.**
       Unifying the schema must not grow file IO in core; the
       embedder loads and passes it, as today.
     - **More surface, same coverage trap.** A larger document has
       more places to silently stop covering an `Authority`.

  ### Spec ownership

  `LEGATE.md` §7 currently specifies the policy file, and `grants.cr`
  parses that YAML. Once `Grants` is core, §7 either moves to a core
  document or says plainly that it documents the Legate SURFACE over a
  core mechanism. A core type specified only inside `LEGATE.md` is the
  drift that produced the four divergences the 2026-08-31 handoff
  complains about. Dismantling parts of LEGATE.md is expected here and
  explicitly sanctioned — that spec predates both the `Effect`/
  `Authority` split and Legate becoming an extension rather than an
  island.

  Note honestly: there is no second consumer today, so parts of this
  generalise on the strength of the argument rather than on evidence.
  Chosen deliberately — the perimeter is precisely what a future
  subsystem should inherit rather than reinvent.

- **LEGATE.md §10's static analysis layer does not exist, and §9/§10
  lean on it in the present tense as though it did.** Found
  2026-09-02, while checking what piece 4 of the authorization work
  would have to rekey. Nothing in `src/` implements any part of §10 —
  there is no analyser file, `risk_walker.cr` contains no reference to
  Legate, and nothing infers, cross-checks or refuses a policy.

  All three subsections are unbuilt:

  - **§10.1 Dataflow.** No grant inference, so no minimum policy and
    no over-grant refusal. Checks 2–5 (taint to argv, taint to path,
    unbounded materialisation, double consumption) likewise. Note that
    checks 2 and 3 are the ones §10.1 itself calls "the
    security-critical pair."
  - **§10.2 Exception discipline.** None of the six rules is enforced.
    Worse than absent for one of them: `retry` is not merely ungated
    but fully implemented (`Compiler#compile_retry`), and §10.2
    forbids it outright as something that "converts a cap into a
    loop." Bare `rescue` and `rescue Exception` are both accepted and
    exercised by existing specs.
  - **§10.3 The inclusion ledger.** No ledger, no sealing, no
    unqualified-call check.

  Why this is Must Fix even though the analyser is a large feature:
  the DOCUMENTATION defect is live and separable from it. §9.2's own
  text says "the static gate ensures it cannot deliberately swallow
  one either," and §9's design-intent paragraph says "§10.2 ensures it
  cannot do so on purpose." Both assert a guarantee that nothing
  provides. A reader — including a model reading the spec to decide
  how defensively to write — is being told a boundary is enforced that
  is not.

  What actually holds today is the RUNTIME property, and it holds
  independently: `FatalSignal` is a plain `Exception`, not a
  `RuntimeError`, so no script `rescue` of any class can catch it
  regardless of syntax. `fatal_signal.cr`'s own comment already states
  this correctly — the gate is a first line of defence and the runtime
  guarantee "does not depend on the gate being correct or even
  present." §9 should say the same rather than the reverse.

  Fix in two parts, the first cheap and the second not:

  1. **Correct the claims now.** §9.2 and §9's design-intent paragraph
     state the runtime property as the guarantee and describe §10.2 as
     an intended additional check, not a current one. Anywhere else
     that says the analyser does something, say it SPECIFIES it.
  2. **Build it later, as its own scoped piece of work**, with §10.1
     keyed on the provider registry from the start (see the
     authorization entry above).

  ### The `retry` contradiction, and why its stated reason is half wrong

  `retry` is a working language feature — `Compiler#compile_retry`
  emits `Op::Retry`, and scripts can use it today. §10.2 forbids it
  outright. Implementing that rule as written is therefore a breaking
  change, not a new check, and it needs deciding rather than
  discovering mid-implementation.

  §10.2 gives two reasons; only the second survives §9.2.

  - *"Converts a cap into a loop"* — largely FALSE as things now
    stand. It would matter if a script could catch a budget
    exhaustion and retry past it, but per-run budgets raise
    `FatalSignal`, which no `rescue` of any class can catch (see
    `fatal_signal.cr`). So `retry` can only loop on the RECOVERABLE
    tier, where retrying is usually pointless and sometimes correct: a
    `TooLarge` on an over-limit read fails identically the second
    time, and a `TooMany` on `max_open_streams` is the case where
    retrying is legitimate BY DESIGN — that limit caps simultaneous
    holdings rather than cumulative consumption, so a script that
    finishes a stream and tries again has genuinely freed the
    resource. This reason reads as a leftover from before §9.2 made
    the fatal tier uncatchable.
  - *"Makes budget analysis undecidable"* — TRUE, and sufficient on
    its own. `retry` puts a back-edge in the control-flow graph, and
    §10.2's whole preamble is about keeping the CFG tractable.

  So the rule is justified, but by tractability rather than by
  security. Whether that justifies banning a working feature outright,
  versus bounding it or accepting reduced analysis precision where it
  appears, is the actual question. Cheaper to answer than it sounds:
  `retry` appears in exactly one spec
  (`classes_and_modules/vm_spec.cr`), so it is implemented but barely
  exercised.

  Recorded rather than fixed wholesale because the analyser is a
  feature, not a bug — but the spec claiming it exists IS a bug, and
  that half should not wait for the other.

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
  logged 2026-08-31. `#json` raises `Legate::Malformed` on a
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

### Tooling

- **Eleven ameba rule classes were excluded per-file rather than
  fixed.** Added 2026-09-01, when the `Effect` rename forced an ameba
  bump from 1.6.4 to 1.7.0 and the new version reported warnings
  across a large part of `src/`. Deferred until after the `add-legate`
  merge so the warnings would not have to be fixed twice, over two
  partly-overlapping sets of files.

  **Cleared 2026-09-02.** `.ameba.yml` now carries no exclusions at
  all. Of the eighteen warnings that survived `--fix`: eight
  `Lint/ElseNil` and six stale `Lint/UnneededDisableDirective` were
  mechanical; `Lint/UselessAssign` and `Lint/VoidOutsideLib` were one
  each; and three `Metrics/CyclomaticComplexity` were real. Two of
  those three were split into genuinely separate methods
  (`NetRule.parse` into its two accepted spellings,
  `RiskWalker#walk_super_target` into its singleton and instance
  branches) rather than silenced. The third, `bootstrap_regexp`, took
  an inline `ameba:disable` with a stated reason, matching the
  convention `range.cr` and `helpers.cr` already use: its branch count
  comes from how many methods `Regexp` has, not from tangled logic.

  Keep the file empty. A per-file exclusion turns a rule off for code
  nobody has looked at yet, including code written later — which is
  how the 1.7.0 warnings reached eighteen files in the first place.

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
