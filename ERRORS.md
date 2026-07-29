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

*None migrated yet.*

## C — Static semantics

*None migrated yet.*

## R — Runtime

*None migrated yet.*

## U — Deliberately unsupported

Full reasoning, alternatives, and enforcement history for each of these
is in [UNSUPPORTED.md](./UNSUPPORTED.md) under the matching code.

|Code|Construct                                 |Raised by     |Placeholders      |
|----|------------------------------------------|--------------|------------------|
|U001|`&blk` parameter capture                  |Compiler      |`param`, `method` |
|U002|`Class.new` / `Module.new`                |VM            |*not yet migrated*|
|U003|Class/module reopening                    |VM            |*not yet migrated*|
|U004|Method definition nested in another method|Compiler      |*not yet migrated*|
|U005|Dynamic dispatch by computed name         |*not enforced*|—                 |
|U006|`eval` / `instance_eval`                  |*not enforced*|—                 |
|U007|Reflection into native internals          |*not enforced*|—                 |

U005–U007 are documented exclusions that nothing currently rejects by
name; see `SCOPE.md`'s `Must Fix` entry.

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
