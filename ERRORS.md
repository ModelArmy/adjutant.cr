# Error codes

Registry of every diagnostic code Adjutant can emit. One row per code,
one line each — for anything longer, the row links out rather than
restating, so each fact lives in exactly one place.

`src/adjutant/error_catalog.cr` is authoritative for the wording; this
file is the reader-facing index. A spec checks the two agree, so a code
added to one and not the other fails the build rather than drifting
quietly.

## Reading a code

The letter encodes the **kind of problem**, not the subsystem that
caught it. That distinction is deliberate: enforcement moves between
phases as the implementation improves (the nested-`def` check moved
from the VM to the compiler in July 2026), and an identifier that
changes when the implementation is refactored is not a stable
identifier — it can't be a translation key, a spec assertion, or
something to look up.

|Letter|Kind                                                             |
|------|-----------------------------------------------------------------|
|`P`   |Malformed syntax — the source could not be parsed                |
|`C`   |Static semantic error — parsed, but rejected before running      |
|`R`   |Runtime fault                                                    |
|`U`   |Deliberately unsupported — see [UNSUPPORTED.md](./UNSUPPORTED.md)|
|`F`   |IFC / risk-flow refusal                                          |

Codes are allocated sequentially within a letter, never reused, and
never renumbered.

## Placeholders

An entry's text may contain `{placeholder}`s filled in from the failure
itself. Every placeholder a code uses is listed in its row below; a
placeholder that appears in the output verbatim, braces and all, means
the diagnostic was constructed without that value and is a bug worth
reporting.

---

## P — Syntax

|Code|Problem                               |Raised by|Placeholders                    |
|----|--------------------------------------|---------|--------------------------------|
|P001|Expected one token, found another     |Parser   |`expected`, `found`             |
|P002|Token can't begin an expression       |Parser   |`found`                         |
|P003|A block construct is missing its `end`|Parser   |`construct`, `found`, `expected`|

P001 has no "why" or "help" on purpose: it stands in for every `expect`
failure the parser can have — a missing `)`, a missing `,`, a missing
`then` — and any explanation general enough to cover all of them would be
too vague to act on. The span labels carry the specifics instead.

P003 exists because missing-`end` is the one syntax error with something
general worth saying, and because its caret alone is misleading: the
parser gives up wherever it ran out of input, which for a missing `end` is
usually the bottom of the file, nowhere near the construct that lost it.
P003 adds a secondary span pointing at the innermost construct still open.

## C — Static semantics

Parsed successfully, but rejected before it could run.

|Code|Problem                               |Raised by|Placeholders|
|----|--------------------------------------|---------|------------|
|C001|Left-hand side of `=` isn't assignable|Compiler |`target`    |
|C002|`redo` used outside any loop          |Compiler |—           |

## R — Runtime

|Code|Fault                                                 |Raised by  |Placeholders      |
|----|------------------------------------------------------|-----------|------------------|
|R001|Constant reassigned after its first assignment        |VM         |`name`            |
|R002|Class variable used outside a class/module body       |VM         |—                 |
|R003|Uninitialized constant                                |VM         |`name`            |
|R004|`::` applied to something that isn't a class or module|VM         |`value`           |
|R005|Unary operator not applicable to this type            |VM         |`operator`, `type`|
|R006|Method definition with no owner to attach to          |VM         |`definition`      |
|R007|`yield` reached with no block passed                  |VM         |`method`          |
|R008|Undefined method or variable                          |VM         |`name`            |
|R009|Module cannot be instantiated                         |VM         |`module`          |
|R010|`require` cannot resolve a module                     |Interpreter|`path`            |

R008 raises a script-visible `NameError`, not `RuntimeError`, matching real
Ruby. The diagnostic code and the rescuable class are set independently on
purpose: the code classifies the failure for whoever reads the report,
while the class governs `rescue` semantics and has to follow Ruby, since
Adjutant is meant to be a proper subset of it.

R001 and U003 come from the same assign-once guard and are told apart by
what is being reassigned: two classes means a reopen (U003, a construct
that is never coming), anything else means an ordinary constant being
written twice (R001, a fault to fix in the script). Reporting both as one
error made each read as noise to whoever hit the other.

## L — Limits

The script is valid; it is just larger than something Adjutant is prepared
to handle. Separate from `R` because the reader's move differs — not "this
is wrong" but "this is too much".

|Code|Limit reached                               |Raised by|Placeholders|
|----|--------------------------------------------|---------|------------|
|L001|Loops nested past the compiler's fixed depth|Compiler |`limit`     |

Whether a limit is host-adjustable varies, and the `help` has to be honest
about it. `ExecutionLimits` exposes `instruction_limit` and
`call_depth_limit` for a host to raise; L001's ceiling is a fixed
compile-time constant guarding a compile-time structure, so its help says
to restructure the script rather than implying a setting exists.

## U — Deliberately unsupported

Full reasoning, alternatives, and enforcement history for each of these
is in [UNSUPPORTED.md](./UNSUPPORTED.md) under the matching code.

|Code|Construct                                 |Raised by     |Placeholders     |
|----|------------------------------------------|--------------|-----------------|
|U001|`&blk` parameter capture                  |Compiler      |`param`, `method`|
|U002|`Class.new` / `Module.new`                |VM            |`class`          |
|U003|Class/module reopening                    |VM            |`name`           |
|U004|Method definition nested in another method|Compiler      |`definition`     |
|U005|Dynamic dispatch by computed name         |*not enforced*|—                |
|U006|`eval` / `instance_eval`                  |*not enforced*|—                |
|U007|Reflection into native internals          |*not enforced*|—                |

U005–U007 are documented exclusions that nothing currently rejects by
name; see `SCOPE.md`'s `Must Fix` entry.

## I — Internal

Adjutant is at fault, not the script. A reader who sees one of these has
nothing to fix in their own code.

|Code|Invariant violated                               |Raised by|Placeholders|
|----|-------------------------------------------------|---------|------------|
|I001|VM read an opcode it has no case for             |VM       |`opcode`    |
|I002|Forward jump target never backpatched            |VM       |`target`    |
|I003|Value stack underflowed its frame base           |VM       |—           |
|I004|Builtin class used before bootstrap registered it|VM       |`class`     |
|I005|Compiler has no case for an AST node             |Compiler |`node`      |

These carry no `help`. There is nothing the reader can do to their script,
and a suggestion would send them editing code that was never at fault —
so renderers append a report footer instead, pointing at
`Interpreter#report_url`. Their `why` is written for whoever ends up
DEBUGGING Adjutant from a pasted report, not for the person who hit it.

Not every internal-looking check belongs here. A type invariant reachable
through a public host API — `Interpreter#invoke_proc` given a non-`Proc`,
for instance — is the integrating host's bug, not Adjutant's, and this
footer would send them upstream to report their own mistake. Those stay
out of the `I` series.

`report_url` defaults to this project's issue tracker and is a property a
host can set. Adjutant is embedded: if an agent harness ships it, that
harness's users should report to whoever ships the harness — they can
triage and forward — rather than to a project they have never heard of.

## F — Risk flow

*None migrated yet.*

---

## Adding a code

1. Add an `Entry` to `ENTRIES` in `src/adjutant/error_catalog.cr`.
2. Add a row here, in the right letter's table.
3. For a `U` code, add the corresponding entry to `UNSUPPORTED.md`.

The consistency spec fails if 1 and 2 disagree.

Wording guidance, learned from the 2026-07-27 enforcement messages:

- **Name the construct.** The reader — often an LLM that generated the
  script — needs to know which thing to stop writing.
- **Never reference a file in this repository.** A repo-internal path
  means nothing to a script author or to a model reading the output.
  Error text must be self-contained.
- **Keep `why` and `help` distinct.** They answer different questions,
  and a reader who understands the why still needs the what-instead.
